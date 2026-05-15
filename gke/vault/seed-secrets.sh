#!/usr/bin/env bash
# seed-secrets.sh — Idempotent Vault configuration.
#
# 1. Enables KV v2 at 'secret/'
# 2. Enables and configures Kubernetes auth
# 3. Writes the litellm-read policy
# 4. Creates Kubernetes auth role 'litellm'         → namespaced SecretStore SA
# 5. Creates Kubernetes auth role 'litellm-cluster' → ClusterSecretStore SA
# 6. Seeds LiteLLM secrets into Vault
#
# Override any variable via environment before running:
#   OPENAI_API_KEY=sk-real DB_PASSWORD=secret bash vault/seed-secrets.sh
set -euo pipefail

VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"
LITELLM_NAMESPACE="${LITELLM_NAMESPACE:-litellm}"
ESO_NAMESPACE="${ESO_NAMESPACE:-external-secrets}"
ESO_SA_NAME="${ESO_SA_NAME:-eso-vault-auth}"
ESO_CLUSTER_SA_NAME="${ESO_CLUSTER_SA_NAME:-eso-vault-auth-cluster}"

OPENAI_API_KEY="${OPENAI_API_KEY:-sk-placeholder-openai-replace-me}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-sk-ant-placeholder-replace-me}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-litellm-master-key-replace-me}"
DATABASE_URL="${DATABASE_URL:-postgresql://user:password@host:5432/litellm}"

log()  { echo -e "\n\033[1;34m  [vault] $*\033[0m"; }
ok()   { echo -e "\033[1;32m  ✓ $*\033[0m"; }
warn() { echo -e "\033[1;33m  ⚠ $*\033[0m"; }

# ── Wait for Vault pod ────────────────────────────────────────────────────────

log "Waiting for Vault pod..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=vault \
  -n "$VAULT_NAMESPACE" \
  --timeout=120s
ok "Vault pod ready"

VAULT_POD=$(kubectl get pods -n "$VAULT_NAMESPACE" \
  -l app.kubernetes.io/name=vault \
  -o jsonpath='{.items[0].metadata.name}')
log "Using pod: $VAULT_POD"

vault_exec() {
  kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
    env VAULT_TOKEN="$VAULT_TOKEN" VAULT_ADDR="http://127.0.0.1:8200" \
    vault "$@"
}

# ── KV v2 ─────────────────────────────────────────────────────────────────────

log "Enabling KV v2 at 'secret/'..."
vault_exec secrets enable -version=2 -path=secret kv 2>/dev/null \
  && ok "KV v2 enabled" \
  || warn "KV v2 already enabled — skipping"

# ── Kubernetes auth ───────────────────────────────────────────────────────────

log "Enabling Kubernetes auth..."
vault_exec auth enable kubernetes 2>/dev/null \
  && ok "Kubernetes auth enabled" \
  || warn "Kubernetes auth already enabled — skipping"

log "Configuring Kubernetes auth backend..."
vault_exec write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"
ok "Kubernetes auth configured"

# ── Policy ────────────────────────────────────────────────────────────────────

log "Writing litellm-read policy..."
# -i is required: kubectl exec without --stdin does not forward the heredoc.
kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
  env VAULT_TOKEN="$VAULT_TOKEN" VAULT_ADDR="http://127.0.0.1:8200" \
  vault policy write litellm-read - <<'POLICY'
path "secret/data/litellm/*" {
  capabilities = ["read"]
}
path "secret/metadata/litellm/*" {
  capabilities = ["list", "read"]
}
POLICY
ok "Policy 'litellm-read' written"

# ── Kubernetes auth roles ─────────────────────────────────────────────────────

# Role for the namespaced SecretStore (litellm namespace)
log "Creating role 'litellm' (namespaced SecretStore SA: $ESO_SA_NAME in $LITELLM_NAMESPACE)..."
vault_exec write auth/kubernetes/role/litellm \
  bound_service_account_names="$ESO_SA_NAME" \
  bound_service_account_namespaces="$LITELLM_NAMESPACE" \
  policies=litellm-read \
  ttl=1h
ok "Role 'litellm' created"

# Role for the ClusterSecretStore (external-secrets namespace)
log "Creating role 'litellm-cluster' (ClusterSecretStore SA: $ESO_CLUSTER_SA_NAME in $ESO_NAMESPACE)..."
vault_exec write auth/kubernetes/role/litellm-cluster \
  bound_service_account_names="$ESO_CLUSTER_SA_NAME" \
  bound_service_account_namespaces="$ESO_NAMESPACE" \
  policies=litellm-read \
  ttl=1h
ok "Role 'litellm-cluster' created"

# ── Seed secrets ──────────────────────────────────────────────────────────────

log "Seeding secrets at secret/litellm/api-keys..."
vault_exec kv put secret/litellm/api-keys \
  OPENAI_API_KEY="$OPENAI_API_KEY" \
  ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  LITELLM_MASTER_KEY="$LITELLM_MASTER_KEY" \
  DATABASE_URL="$DATABASE_URL"
ok "Secrets seeded at secret/litellm/api-keys"

echo ""
log "Done. Verify:"
echo "  kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- \\"
echo "    env VAULT_TOKEN=root VAULT_ADDR=http://127.0.0.1:8200 \\"
echo "    vault kv get secret/litellm/api-keys"
