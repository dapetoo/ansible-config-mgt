# vault-ha — Production Vault on GKE

On-cluster HA Vault with Transit auto-unseal, no cloud KMS dependency.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ vault-unseal namespace                                              │
│                                                                     │
│  vault-unseal (StatefulSet, 1 replica, Raft)                        │
│    • Holds transit/keys/main-vault-autounseal                       │
│    • Sealed by Shamir — 1 key stored in K8s Secret vault-unseal-keys│
│                                                                     │
│  vault-unseal-watcher (Deployment)                                  │
│    • Polls every 30 s, auto-unseals using key from vault-unseal-keys│
└─────────────────────────────────────────────────────────────────────┘
         │  Transit seal
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│ vault namespace                                                     │
│                                                                     │
│  vault-0 (StatefulSet, 1 replica, Raft standalone)                  │
│    • Auto-unseals via Transit whenever vault-unseal is reachable    │
│    • seal.hcl mounted from K8s Secret vault-transit-seal            │
└─────────────────────────────────────────────────────────────────────┘
         │  Kubernetes auth
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│ external-secrets namespace                                          │
│   ClusterSecretStore (vault-cluster-backend)                        │
│   SA: eso-vault-auth-cluster → Vault role: eso-cluster             │
│   Policy: read ee/data/*                                            │
│                                                                     │
│ ai-gateway namespace                                                │
│   SecretStore (vault-backend)                                       │
│   SA: eso-vault-auth → Vault role: eso-ai-gateway                  │
│   Policy: read ee/data/ai-gateway/* only                            │
└─────────────────────────────────────────────────────────────────────┘
```

## Files

```
vault-ha/
├── install.sh                        # Full orchestration — run first
├── unseal-vault/
│   ├── values.yaml                   # Helm values for vault-unseal
│   └── watcher.yaml                  # Auto-unseal Deployment + RBAC
├── main-vault/
│   ├── values.yaml                   # Helm values for main HA Vault
│   └── init.sh                       # K8s auth, policies, ESO roles
└── eso/
    ├── clusterserviceaccount.yaml    # SA for ClusterSecretStore
    ├── clustersecretstore.yaml       # Cluster-wide store (ee/data/*)
    ├── secretstore.yaml              # SA + namespaced store (ai-gateway)
    └── externalsecret.yaml           # Example ExternalSecret
```

## Install order

```bash
# 1. Install ESO (skip if already present)
helm repo add external-secrets https://charts.external-secrets.io
helm upgrade --install eso external-secrets/external-secrets \
  -n external-secrets --create-namespace

# 2. Run full Vault install
bash vault-ha/install.sh

# 3. Configure k8s auth + ESO roles
bash vault-ha/main-vault/init.sh

# 4. Apply ESO manifests
kubectl create namespace ai-gateway --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f vault-ha/eso/

# 5. Seed secrets
kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN="$(kubectl get secret vault-root-token -n vault \
    -o jsonpath='{.data.root-token}' | base64 -d)" \
  VAULT_ADDR=http://127.0.0.1:8200 \
  vault kv put ee/ai-gateway/litellm \
    LITELLM_MASTER_KEY=sk-... \
    ANTHROPIC_API_KEY=sk-ant-...
```

## K8s Secrets created by install.sh

| Secret | Namespace | Contents |
|--------|-----------|----------|
| `vault-unseal-keys` | `vault-unseal` | Shamir unseal key + unseal Vault root token |
| `vault-transit-seal` | `vault` | `seal.hcl` with Transit token (mounted into main vault pods) |
| `vault-root-token` | `vault` | Main vault root token |
| `vault-recovery-keys` | `vault` | Recovery keys (keep safe — used if Transit Vault is lost) |

> The transit token in `vault-transit-seal` has a 24 h period and is
> auto-renewed by the main Vault's seal mechanism (`disable_renewal = "false"`).

## Vault UI

```bash
kubectl port-forward -n vault svc/vault 8200:8200
# open http://localhost:8200
# token: kubectl get secret vault-root-token -n vault -o jsonpath='{.data.root-token}' | base64 -d
```

## Disaster recovery

If the Transit Vault (`vault-unseal`) is lost along with its PVC, the main
vault will not be able to auto-unseal. To recover:

1. Redeploy `vault-unseal` and re-init it.
2. Restore the transit key from backup **or** create a new key and reconfigure
   `vault-transit-seal` secret + restart main vault pods.
3. Use the `vault-recovery-keys` (stored in the `vault` namespace) to perform
   a `vault operator generate-root` if the root token is also lost.

Recommendation: export `vault-recovery-keys` to a secure offline location
(password manager, HSM) after install.
