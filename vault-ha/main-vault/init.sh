#!/usr/bin/env bash
# vault-ha/main-vault/init.sh
#
# Configures the main HA Vault after it has been initialized by install.sh.
# Run this ONCE after install.sh completes and vault-0 shows status "active".
#
# What this script does:
#   1. Enables KV v2 at the 'ee' mount (matches production ESO config)
#   2. Enables Kubernetes auth
#   3. Writes policies for ClusterSecretStore and namespaced SecretStore
#   4. Creates Kubernetes auth roles bound to the ESO service accounts
#
# Prerequisites:
#   - install.sh has run and 'vault-root-token' secret exists in 'vault' ns
#   - kubectl context is pointing at the GKE cluster
#   - ESO service accounts exist (apply eso/ manifests first)

set -euo pipefail

MAIN_NAMESPACE="vault"
MAIN_POD="vault-0"
KV_MOUNT="ee"
ESO_NAMESPACE="external-secrets"
AI_GATEWAY_NAMESPACE="ai-gateway"

# ── helpers ──────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

vault_exec() {
  kubectl exec -n "$MAIN_NAMESPACE" "$MAIN_POD" -- \
    env VAULT_TOKEN="$MAIN_ROOT_TOKEN" VAULT_ADDR="http://127.0.0.1:8200" \
    vault "$@"
}

vault_exec_i() {
  kubectl exec -i -n "$MAIN_NAMESPACE" "$MAIN_POD" -- \
    env VAULT_TOKEN="$MAIN_ROOT_TOKEN" VAULT_ADDR="http://127.0.0.1:8200" \
    vault "$@"
}

enable_if_missing() {
  local type="$1" path="$2"
  vault_exec "$type" list 2>/dev/null | grep -q "^${path}/" \
    || vault_exec "$type" enable -path="$path" "${@:3}" \
    && echo "$type $path: already enabled"
}

# ── load root token ───────────────────────────────────────────────────────────

MAIN_ROOT_TOKEN=$(kubectl get secret vault-root-token \
  -n "$MAIN_NAMESPACE" \
  -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d 2>/dev/null) \
  || die "vault-root-token secret not found in '$MAIN_NAMESPACE'. Run install.sh first."

[ -n "$MAIN_ROOT_TOKEN" ] || die "root token is empty"

echo "==> vault-0 status"
vault_exec status || true

# ── KV v2 ────────────────────────────────────────────────────────────────────

echo ""
echo "==> Enabling KV v2 at '$KV_MOUNT'"
vault_exec secrets enable -path="$KV_MOUNT" kv-v2 2>/dev/null \
  || echo "    already enabled"

# ── Kubernetes auth ───────────────────────────────────────────────────────────

echo ""
echo "==> Enabling Kubernetes auth"
vault_exec auth enable kubernetes 2>/dev/null || echo "    already enabled"

echo "    Configuring Kubernetes auth"
vault_exec write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local"

# ── Policies ──────────────────────────────────────────────────────────────────

echo ""
echo "==> Writing policy: eso-cluster-read (ClusterSecretStore — full $KV_MOUNT read)"
vault_exec_i policy write eso-cluster-read - <<POLICY
path "${KV_MOUNT}/data/*" {
  capabilities = ["read"]
}
path "${KV_MOUNT}/metadata/*" {
  capabilities = ["list", "read"]
}
POLICY

echo "==> Writing policy: eso-ai-gateway-read (namespaced SecretStore — ai-gateway subtree only)"
vault_exec_i policy write eso-ai-gateway-read - <<POLICY
path "${KV_MOUNT}/data/ai-gateway/*" {
  capabilities = ["read"]
}
path "${KV_MOUNT}/metadata/ai-gateway/*" {
  capabilities = ["list", "read"]
}
POLICY

# ── Kubernetes auth roles ─────────────────────────────────────────────────────

echo ""
echo "==> Creating Kubernetes auth role: eso-cluster"
echo "    Bound SA: eso-vault-auth-cluster in $ESO_NAMESPACE"
vault_exec write auth/kubernetes/role/eso-cluster \
  bound_service_account_names="eso-vault-auth-cluster" \
  bound_service_account_namespaces="$ESO_NAMESPACE" \
  policies="eso-cluster-read" \
  ttl=1h

echo "==> Creating Kubernetes auth role: eso-ai-gateway"
echo "    Bound SA: eso-vault-auth in $AI_GATEWAY_NAMESPACE"
vault_exec write auth/kubernetes/role/eso-ai-gateway \
  bound_service_account_names="eso-vault-auth" \
  bound_service_account_namespaces="$AI_GATEWAY_NAMESPACE" \
  policies="eso-ai-gateway-read" \
  ttl=1h

# ── Seed an example secret ────────────────────────────────────────────────────

echo ""
echo "==> Seeding example secret at $KV_MOUNT/ai-gateway/example"
vault_exec kv put "$KV_MOUNT/ai-gateway/example" \
  EXAMPLE_KEY="replace-me"

echo ""
echo "Done. Next steps:"
echo "  1. Apply ESO manifests:  kubectl apply -f vault-ha/eso/"
echo "  2. Verify ClusterSecretStore: kubectl get clustersecretstore vault-cluster-backend"
echo "  3. Verify SecretStore:        kubectl get secretstore vault-backend -n ai-gateway"
echo "  4. Write real secrets:        vault kv put $KV_MOUNT/ai-gateway/<path> KEY=value"
