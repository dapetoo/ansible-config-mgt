#!/usr/bin/env bash
# gke/install.sh — Full Vault → ESO → LiteLLM install for GKE.
#
# Prerequisites:
#   - kubectl context pointed at the GKE cluster
#   - helm >= 3.x
#   - ESO already installed in the external-secrets namespace
#
# Dependency order:
#   1. Namespaces
#   2. Vault (dev mode) → auth, policy, roles, secrets
#   3. PostgreSQL
#   4. ESO ServiceAccounts (namespaced + cluster)
#   5. SecretStore + ClusterSecretStore
#   6. ExternalSecret → wait for litellm-secrets
#   7. LiteLLM
#
# Override any credential via env var:
#   OPENAI_API_KEY=sk-real DB_PASSWORD=secret bash gke/install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
ESO_NAMESPACE="${ESO_NAMESPACE:-external-secrets}"
LITELLM_NAMESPACE="${LITELLM_NAMESPACE:-litellm}"

VAULT_CHART_VERSION="0.32.0"
LITELLM_CHART_VERSION="1.82.3"

VAULT_TOKEN="${VAULT_TOKEN:-root}"
DATABASE_URL="${DATABASE_URL:-postgresql://user:password@host:5432/litellm}"
OPENAI_API_KEY="${OPENAI_API_KEY:-sk-placeholder-openai-replace-me}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-sk-ant-placeholder-replace-me}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-litellm-master-key-replace-me}"

log()     { echo -e "\n\033[1;34m==> $*\033[0m"; }
success() { echo -e "\033[1;32m  ✓ $*\033[0m"; }
warn()    { echo -e "\033[1;33m  ⚠ $*\033[0m"; }
die()     { echo -e "\033[1;31m  ✗ $*\033[0m" >&2; exit 1; }

# ── Pre-flight ─────────────────────────────────────────────────────────────────

log "Pre-flight checks..."
command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
command -v helm    >/dev/null 2>&1 || die "helm not found"
kubectl cluster-info &>/dev/null   || die "kubectl cannot reach cluster"

# Fail fast if ESO is not installed — script skips install but depends on it.
kubectl get crd externalsecrets.external-secrets.io &>/dev/null \
  || die "ESO CRDs not found. Install ESO first:
  helm repo add external-secrets https://charts.external-secrets.io
  helm upgrade --install external-secrets external-secrets/external-secrets \\
    -n external-secrets --create-namespace"

success "Pre-flight passed"

# ── Step 1: Helm repos ─────────────────────────────────────────────────────────

log "Adding Helm repos..."
helm repo add hashicorp https://helm.releases.hashicorp.com --force-update
helm repo update hashicorp
success "Helm repos ready"

# ── Step 2: Namespaces ─────────────────────────────────────────────────────────

log "Creating namespaces..."
for ns in "$VAULT_NAMESPACE" "$LITELLM_NAMESPACE"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  success "Namespace '$ns' ready"
done

# ── Step 3: Vault ─────────────────────────────────────────────────────────────

log "Deploying Vault (dev mode, chart $VAULT_CHART_VERSION)..."
helm upgrade --install vault hashicorp/vault \
  -n "$VAULT_NAMESPACE" \
  --version "$VAULT_CHART_VERSION" \
  --values  "$SCRIPT_DIR/vault/values.yaml" \
  --wait --timeout 120s
success "Vault deployed"

# ── Step 4: Configure Vault ────────────────────────────────────────────────────

log "Configuring Vault (auth, policies, roles, secrets)..."
export VAULT_NAMESPACE VAULT_TOKEN LITELLM_NAMESPACE ESO_NAMESPACE
export OPENAI_API_KEY ANTHROPIC_API_KEY LITELLM_MASTER_KEY DATABASE_URL
bash "$SCRIPT_DIR/vault/seed-secrets.sh"
success "Vault configured"

# ── Step 5: ESO ServiceAccounts ───────────────────────────────────────────────

log "Creating ESO ServiceAccounts..."
kubectl apply -f "$SCRIPT_DIR/eso/serviceaccount.yaml"
success "eso-vault-auth (litellm ns) ready"

kubectl apply -f "$SCRIPT_DIR/eso/clusterserviceaccount.yaml"
success "eso-vault-auth-cluster (external-secrets ns) ready"

# ── Step 6: SecretStore + ClusterSecretStore ───────────────────────────────────

log "Applying SecretStore (namespaced, litellm)..."
kubectl apply -f "$SCRIPT_DIR/eso/secretstore.yaml"
sleep 8
STORE_STATUS=$(kubectl get secretstore vault-backend -n "$LITELLM_NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
[ "$STORE_STATUS" = "True" ] \
  && success "SecretStore 'vault-backend' is Ready" \
  || warn "SecretStore status: $STORE_STATUS — check: kubectl describe secretstore vault-backend -n $LITELLM_NAMESPACE"

log "Applying ClusterSecretStore..."
kubectl apply -f "$SCRIPT_DIR/eso/clustersecretstore.yaml"
sleep 8
CSS_STATUS=$(kubectl get clustersecretstore vault-cluster-backend \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
[ "$CSS_STATUS" = "True" ] \
  && success "ClusterSecretStore 'vault-cluster-backend' is Ready" \
  || warn "ClusterSecretStore status: $CSS_STATUS — check: kubectl describe clustersecretstore vault-cluster-backend"

# ── Step 7: ExternalSecret ────────────────────────────────────────────────────

log "Applying ExternalSecret..."
kubectl apply -f "$SCRIPT_DIR/eso/externalsecret.yaml"

log "Waiting for 'litellm-secrets' K8s Secret (up to 2 min)..."
for i in $(seq 1 24); do
  if kubectl get secret litellm-secrets -n "$LITELLM_NAMESPACE" &>/dev/null; then
    success "'litellm-secrets' created"
    break
  fi
  echo "  Waiting... ($i/24)"
  sleep 5
done
kubectl get secret litellm-secrets -n "$LITELLM_NAMESPACE" &>/dev/null \
  || die "'litellm-secrets' not created. Debug: kubectl describe externalsecret litellm-secrets -n $LITELLM_NAMESPACE"

# ── Step 8: LiteLLM ───────────────────────────────────────────────────────────

log "Deploying LiteLLM (chart $LITELLM_CHART_VERSION)..."
helm upgrade --install litellm \
  oci://ghcr.io/berriai/litellm-helm \
  -n "$LITELLM_NAMESPACE" \
  --version "$LITELLM_CHART_VERSION" \
  --values  "$SCRIPT_DIR/litellm/values.yaml" \
  --wait --timeout 300s
success "LiteLLM deployed"

# ── Done ───────────────────────────────────────────────────────────────────────

log "Installation complete!"
cat <<EOF

Access LiteLLM:
  kubectl port-forward svc/litellm -n $LITELLM_NAMESPACE 4000:4000
  curl http://localhost:4000/health

Access Vault UI:
  kubectl port-forward svc/vault -n $VAULT_NAMESPACE 8200:8200
  http://localhost:8200  (Token: root)

Update a secret (e.g. swap DATABASE_URL):
  kubectl exec -n $VAULT_NAMESPACE vault-0 -- \\
    env VAULT_TOKEN=root VAULT_ADDR=http://127.0.0.1:8200 \\
    vault kv patch secret/litellm/api-keys DATABASE_URL="postgresql://..."

Verify secrets synced:
  kubectl get secret litellm-secrets -n $LITELLM_NAMESPACE -o yaml
  kubectl get externalsecret litellm-secrets -n $LITELLM_NAMESPACE
  kubectl get secretstore vault-backend -n $LITELLM_NAMESPACE
  kubectl get clustersecretstore vault-cluster-backend
EOF
