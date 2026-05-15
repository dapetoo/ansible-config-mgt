#!/usr/bin/env bash
# vault-ha/install.sh
#
# Full install orchestration for the production Vault HA setup on GKE.
# Run from the repo root: bash vault-ha/install.sh
#
# What this script installs / configures:
#   1. vault-unseal  — standalone Vault (Transit seal backend, Shamir init)
#   2. vault-unseal-watcher — auto-unseal Deployment
#   3. vault (main)  — 3-replica HA Vault with Transit auto-unseal
#   4. Main Vault init — stores root token; Transit seal keys created here
#
# After this script:
#   - Run: bash vault-ha/main-vault/init.sh   (k8s auth, policies, roles)
#   - Then: kubectl apply -f vault-ha/eso/     (ESO stores + example secret)
#
# Prerequisites:
#   - kubectl context pointed at the GKE cluster
#   - helm >= 3.x
#   - HashiCorp Helm repo added (script adds it if missing)
#   - ESO already installed in 'external-secrets' namespace
#     (install separately: helm install eso external-secrets/external-secrets)

set -euo pipefail

UNSEAL_NAMESPACE="vault-unseal"
VAULT_NAMESPACE="vault"
CHART_VERSION="0.32.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── helpers ──────────────────────────────────────────────────────────────────

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

wait_for_pod() {
  local ns="$1" label="$2" timeout="${3:-120}"
  log "Waiting for pod ($label) in $ns..."
  kubectl wait pod \
    -n "$ns" \
    -l "$label" \
    --for=condition=Ready \
    --timeout="${timeout}s"
}

unseal_exec() {
  kubectl exec -n "$UNSEAL_NAMESPACE" "$UNSEAL_POD" -- \
    env VAULT_TOKEN="$UNSEAL_ROOT_TOKEN" VAULT_ADDR="http://127.0.0.1:8200" \
    vault "$@"
}

unseal_exec_i() {
  kubectl exec -i -n "$UNSEAL_NAMESPACE" "$UNSEAL_POD" -- \
    env VAULT_TOKEN="$UNSEAL_ROOT_TOKEN" VAULT_ADDR="http://127.0.0.1:8200" \
    vault "$@"
}

# ── Phase 0: Helm repo ───────────────────────────────────────────────────────

log "Adding HashiCorp Helm repo"
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo update hashicorp

# ── Phase 1: Deploy vault-unseal ──────────────────────────────────────────────

log "Deploying vault-unseal"
kubectl create namespace "$UNSEAL_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install vault-unseal hashicorp/vault \
  -n "$UNSEAL_NAMESPACE" \
  --version "$CHART_VERSION" \
  -f "$SCRIPT_DIR/unseal-vault/values.yaml" \
  --wait --timeout 3m

UNSEAL_POD=$(kubectl get pod -n "$UNSEAL_NAMESPACE" \
  -l "app.kubernetes.io/name=vault" \
  -o jsonpath='{.items[0].metadata.name}')
log "vault-unseal pod: $UNSEAL_POD"

# ── Phase 2: Init vault-unseal ────────────────────────────────────────────────

INIT_STATUS=$(kubectl exec -n "$UNSEAL_NAMESPACE" "$UNSEAL_POD" -- \
  vault status -format=json 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('initialized','false'))" \
  2>/dev/null || echo "false")

if [ "$INIT_STATUS" = "False" ] || [ "$INIT_STATUS" = "false" ]; then
  log "Initialising vault-unseal (1 key share, threshold 1)"
  INIT_JSON=$(kubectl exec -n "$UNSEAL_NAMESPACE" "$UNSEAL_POD" -- \
    vault operator init -key-shares=1 -key-threshold=1 -format=json)

  UNSEAL_KEY=$(echo "$INIT_JSON" | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['unseal_keys_b64'][0])")
  UNSEAL_ROOT_TOKEN=$(echo "$INIT_JSON" | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")

  kubectl create secret generic vault-unseal-keys \
    -n "$UNSEAL_NAMESPACE" \
    --from-literal=unseal-key-0="$UNSEAL_KEY" \
    --from-literal=root-token="$UNSEAL_ROOT_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "Unsealing vault-unseal"
  kubectl exec -n "$UNSEAL_NAMESPACE" "$UNSEAL_POD" -- \
    vault operator unseal "$UNSEAL_KEY"
else
  log "vault-unseal already initialised"
  UNSEAL_KEY=$(kubectl get secret vault-unseal-keys \
    -n "$UNSEAL_NAMESPACE" -o jsonpath='{.data.unseal-key-0}' | base64 -d)
  UNSEAL_ROOT_TOKEN=$(kubectl get secret vault-unseal-keys \
    -n "$UNSEAL_NAMESPACE" -o jsonpath='{.data.root-token}' | base64 -d)
fi

# ── Phase 3: Deploy watcher ───────────────────────────────────────────────────

log "Deploying vault-unseal-watcher"
kubectl apply -f "$SCRIPT_DIR/unseal-vault/watcher.yaml"

# ── Phase 4: Enable Transit on vault-unseal ───────────────────────────────────

log "Enabling Transit secrets engine on vault-unseal"
unseal_exec secrets enable transit 2>/dev/null || log "transit already enabled"

log "Creating Transit key: main-vault-autounseal"
unseal_exec write -f transit/keys/main-vault-autounseal 2>/dev/null \
  || log "key already exists"

log "Writing transit-seal policy on vault-unseal"
unseal_exec_i policy write main-vault-transit - <<'POLICY'
path "transit/encrypt/main-vault-autounseal" {
  capabilities = ["update"]
}
path "transit/decrypt/main-vault-autounseal" {
  capabilities = ["update"]
}
POLICY

log "Creating periodic transit token (24 h period, auto-renewed by main vault)"
TRANSIT_TOKEN=$(unseal_exec token create \
  -policy=main-vault-transit \
  -period=24h \
  -orphan=true \
  -format=json \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])")

# ── Phase 5: Create vault-transit-seal secret in vault namespace ───────────────

log "Creating vault-transit-seal secret in '$VAULT_NAMESPACE'"
kubectl create namespace "$VAULT_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Vault loads every .hcl file under /vault/config/. This file is mounted at
# /vault/config/seal.hcl alongside the raft config generated by the chart.
SEAL_HCL=$(cat <<EOF
seal "transit" {
  address         = "http://vault-unseal.${UNSEAL_NAMESPACE}.svc.cluster.local:8200"
  token           = "${TRANSIT_TOKEN}"
  key_name        = "main-vault-autounseal"
  mount_path      = "transit"
  disable_renewal = "false"
}
EOF
)

kubectl create secret generic vault-transit-seal \
  -n "$VAULT_NAMESPACE" \
  --from-literal=seal.hcl="$SEAL_HCL" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── Phase 6: Deploy main Vault ────────────────────────────────────────────────

log "Deploying main HA Vault"
helm upgrade --install vault hashicorp/vault \
  -n "$VAULT_NAMESPACE" \
  --version "$CHART_VERSION" \
  -f "$SCRIPT_DIR/main-vault/values.yaml" \
  --wait --timeout 5m

log "Waiting for vault-0 to become ready"
kubectl wait pod vault-0 \
  -n "$VAULT_NAMESPACE" \
  --for=condition=Ready \
  --timeout=120s 2>/dev/null || log "vault-0 not yet Ready (may be awaiting init)"

# ── Phase 7: Init main Vault ──────────────────────────────────────────────────

MAIN_INIT=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- \
  vault status -format=json 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('initialized','false'))" \
  2>/dev/null || echo "false")

if [ "$MAIN_INIT" = "False" ] || [ "$MAIN_INIT" = "false" ]; then
  log "Initialising main vault (Transit seal — produces recovery keys, not unseal keys)"
  MAIN_INIT_JSON=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- \
    vault operator init -format=json)

  MAIN_ROOT_TOKEN=$(echo "$MAIN_INIT_JSON" | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")

  # Store root token — needed for init.sh and future admin ops
  kubectl create secret generic vault-root-token \
    -n "$VAULT_NAMESPACE" \
    --from-literal=root-token="$MAIN_ROOT_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Store recovery keys (keep safe — needed if Transit Vault is ever lost)
  RECOVERY_KEYS=$(echo "$MAIN_INIT_JSON" | \
    python3 -c "import sys,json; print('\n'.join(json.load(sys.stdin).get('recovery_keys_b64',[])))")
  kubectl create secret generic vault-recovery-keys \
    -n "$VAULT_NAMESPACE" \
    --from-literal=recovery-keys="$RECOVERY_KEYS" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "Main vault initialised. Root token stored in 'vault-root-token' (vault ns)"
else
  log "Main vault already initialised"
fi

log ""
log "===== Install complete ====="
log ""
log "Next steps:"
log "  1. Verify all 3 vault pods are Ready:"
log "       kubectl get pods -n vault"
log ""
log "  2. Run init.sh to configure k8s auth, policies, and ESO roles:"
log "       bash vault-ha/main-vault/init.sh"
log ""
log "  3. Apply ESO manifests:"
log "       kubectl apply -f vault-ha/eso/"
log ""
log "  4. Seed secrets in Vault:"
log "       vault kv put ee/ai-gateway/<path> KEY=value"
