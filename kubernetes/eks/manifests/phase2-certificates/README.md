## Phase 2: Certificates (Vault + cert-manager)

Deploys HashiCorp Vault in HA mode and cert-manager for automated certificate management.

## What's Deployed

**HashiCorp Vault:**
- 3-replica StatefulSet with Raft storage backend
- 10Gi encrypted persistent volumes per replica
- Vault UI enabled (ClusterIP service)
- PKI secrets engine configured
- Kubernetes authentication enabled

**cert-manager:**
- cert-manager controller
- webhook
- cainjector
- CRDs for Certificate, ClusterIssuer, Issuer

**PKI Configuration:**
- Root CA generated (10-year validity)
- Two PKI roles:
  - `cockroachdb-node`: For CockroachDB node certificates (server + client)
  - `cockroachdb-client`: For CockroachDB client certificates
- Vault ClusterIssuer configured for cert-manager

## Prerequisites

- Phase 1 complete (EKS cluster with StorageClass)
- kubectl, helm, jq installed

## Deployment

```bash
cd manifests/phase2-certificates
./setup.sh
```

The script will:
1. Install Vault in HA mode (3 replicas)
2. Initialize Vault (generates unseal keys and root token)
3. Unseal all Vault pods
4. Configure PKI secrets engine with root CA
5. Configure Kubernetes authentication
6. Install cert-manager
7. Create Vault ClusterIssuer
8. Test certificate issuance

## Important Files

After deployment, `vault-keys.json` will be created containing:
- 5 unseal keys (need 3 of 5 to unseal Vault)
- Root token

**⚠️ CRITICAL**: Store `vault-keys.json` securely! These keys are required to:
- Unseal Vault after pod restarts
- Perform administrative operations
- Recover from failures

In production, these should be stored in:
- AWS Secrets Manager
- Hardware Security Module (HSM)
- Split among multiple trusted administrators

## Validation

```bash
# Check Vault pods
kubectl get pods -n vault

# Check Vault status
kubectl exec -n vault vault-0 -- vault status

# Check cert-manager pods
kubectl get pods -n cert-manager

# Check ClusterIssuer
kubectl get clusterissuer

# Check test certificate
kubectl get certificate test-cert -n default
kubectl describe certificate test-cert -n default
```

## Usage

### Requesting a Certificate

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: my-cert
  namespace: my-namespace
spec:
  secretName: my-cert-secret
  issuerRef:
    name: vault-issuer
    kind: ClusterIssuer
  commonName: my-service.my-namespace.svc.cluster.local
  dnsNames:
    - my-service
    - my-service.my-namespace
    - my-service.my-namespace.svc
    - my-service.my-namespace.svc.cluster.local
  duration: 2160h  # 90 days
  renewBefore: 360h  # 15 days before expiry
```

cert-manager will automatically:
1. Request certificate from Vault PKI
2. Store cert, key, and CA in the specified secret
3. Renew before expiration

### Accessing Vault UI

```bash
# Port-forward to Vault
kubectl port-forward -n vault svc/vault-ui 8200:8200

# Open browser
open http://localhost:8200

# Login with root token from vault-keys.json
```

## Unsealing Vault After Restart

If Vault pods restart, they will be sealed and need to be unsealed:

```bash
# Get unseal keys from vault-keys.json
UNSEAL_KEY_1=$(jq -r '.unseal_keys_b64[0]' vault-keys.json)
UNSEAL_KEY_2=$(jq -r '.unseal_keys_b64[1]' vault-keys.json)
UNSEAL_KEY_3=$(jq -r '.unseal_keys_b64[2]' vault-keys.json)

# Unseal each pod (need 3 keys)
for i in 0 1 2; do
  kubectl exec -n vault vault-$i -- vault operator unseal $UNSEAL_KEY_1
  kubectl exec -n vault vault-$i -- vault operator unseal $UNSEAL_KEY_2
  kubectl exec -n vault vault-$i -- vault operator unseal $UNSEAL_KEY_3
done
```

## Teardown

```bash
cd ../..
./teardown.sh --phase 2
```

This will remove:
- Test certificate
- Vault ClusterIssuer
- cert-manager (Helm release)
- cert-manager namespace
- cert-manager CRDs
- Vault (Helm release)
- Vault namespace
- Vault PVCs

## Troubleshooting

### Vault Pod Not Ready

```bash
# Check pod status
kubectl describe pod vault-0 -n vault

# Check Vault logs
kubectl logs vault-0 -n vault

# Vault is likely sealed - unseal it
kubectl exec -n vault vault-0 -- vault status
```

### Certificate Not Issued

```bash
# Check Certificate status
kubectl describe certificate my-cert -n my-namespace

# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager

# Check ClusterIssuer status
kubectl describe clusterissuer vault-issuer

# Test Vault connectivity from cert-manager
kubectl exec -n cert-manager <cert-manager-pod> -- wget -O- http://vault.vault.svc.cluster.local:8200/v1/sys/health
```

### Vault Authentication Errors

```bash
# Verify Kubernetes auth is configured
kubectl exec -n vault vault-0 -- vault auth list

# Verify role exists
kubectl exec -n vault vault-0 -- vault read auth/kubernetes-east/role/cert-manager

# Verify policy exists
kubectl exec -n vault vault-0 -- vault policy read cert-manager
```

## Next Steps

Proceed to Phase 3: CockroachDB Operator
