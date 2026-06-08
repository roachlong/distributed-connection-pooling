## Phase 3: CockroachDB Operator

Deploys the CockroachDB Kubernetes Operator which manages CockroachDB cluster lifecycle.

## What's Deployed

**CockroachDB Operator:**
- Kubernetes operator for managing CockroachDB clusters
- Custom Resource Definitions (CRDs) for CockroachDB
- Controller that reconciles desired vs actual state
- Automated operations: scaling, upgrades, failover

**Namespaces:**
- `cockroach-operator-system` - Operator deployment
- `cockroachdb` - CockroachDB cluster namespace (prepared for Phase 4)

**Custom Resources:**
- `CrdbCluster` - Defines a CockroachDB cluster
- Enables declarative cluster management via YAML

## Prerequisites

- Phase 1 complete (EKS cluster with StorageClass)
- Phase 2 complete (Vault + cert-manager)
- kubectl, helm installed

## Deployment

```bash
cd manifests/phase3-operator
./setup.sh
```

The script will:
1. Verify operator version exists on GitHub
2. Install CockroachDB CRDs via kubectl
3. Install CockroachDB Operator via kubectl
4. Create CockroachDB cluster namespace (`cockroachdb`)
5. Verify operator is running

## Validation

```bash
# Check operator deployment
kubectl get deployment -n cockroach-operator-system

# Check operator pods
kubectl get pods -n cockroach-operator-system

# Check CRDs
kubectl get crd | grep cockroach

# Check operator logs
kubectl logs -n cockroach-operator-system deployment/cockroach-operator-manager

# Check operator version
kubectl get deployment cockroach-operator-manager -n cockroach-operator-system -o jsonpath='{.spec.template.spec.containers[*].image}' && echo
```

## Expected Output

```bash
# Operator deployment should be Available
NAME                          READY   UP-TO-DATE   AVAILABLE   AGE
cockroach-operator-manager    1/1     1            1           2m

# Operator pods should be Running
NAME                                          READY   STATUS    RESTARTS   AGE
cockroach-operator-manager-xxxxxxxxxx-xxxxx   2/2     Running   0          2m

# CRD should exist
NAME                                    CREATED AT
crdbclusters.crdb.cockroachlabs.com     2026-06-08T12:00:00Z
```

## What the Operator Does

The CockroachDB Operator:
- **Automates cluster lifecycle**: Create, scale, upgrade, delete
- **Manages certificates**: Integrates with cert-manager for TLS
- **Handles failures**: Automatic pod recovery and rescheduling
- **Enables rolling updates**: Zero-downtime version upgrades
- **Monitors health**: Ensures cluster meets desired state

## Architecture

```
┌─────────────────────────────────────────┐
│  cockroach-operator-system namespace   │
│  ┌───────────────────────────────────┐ │
│  │   CockroachDB Operator Pod        │ │
│  │   - Watches CrdbCluster resources │ │
│  │   - Reconciles desired state      │ │
│  │   - Manages StatefulSets          │ │
│  │   - Issues certificates           │ │
│  └───────────────────────────────────┘ │
└─────────────────────────────────────────┘
              │
              │ watches
              ▼
┌─────────────────────────────────────────┐
│  cockroachdb namespace                  │
│  ┌───────────────────────────────────┐ │
│  │  CrdbCluster Custom Resource      │ │
│  │  (created in Phase 4)             │ │
│  └───────────────────────────────────┘ │
│              │                          │
│              │ creates/manages          │
│              ▼                          │
│  ┌───────────────────────────────────┐ │
│  │  CockroachDB StatefulSet          │ │
│  │  - CockroachDB pods               │ │
│  │  - PVCs                           │ │
│  │  - Services                       │ │
│  └───────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

## Operator vs Manual Deployment

**With Operator (what we're doing):**
- ✅ Declarative configuration (YAML)
- ✅ Automatic scaling and upgrades
- ✅ Built-in best practices
- ✅ Self-healing
- ✅ Certificate management integration

**Without Operator:**
- ❌ Manual StatefulSet management
- ❌ Manual certificate creation/rotation
- ❌ Manual scaling procedures
- ❌ Complex upgrade processes

## Configuration

Operator configuration is determined by the manifests from GitHub. Current settings:
- Version: `${COCKROACHDB_OPERATOR_VERSION}` (from config.env)
- Namespace: `cockroach-operator-system`
- Watch all namespaces: Yes (can manage clusters in any namespace)
- Installation source: `https://github.com/cockroachdb/cockroach-operator`

## Troubleshooting

### Operator Pod Not Starting

```bash
# Check deployment status
kubectl describe deployment cockroach-operator-manager -n cockroach-operator-system

# Check pod status
kubectl describe pod -n cockroach-operator-system -l control-plane=controller-manager

# Check logs
kubectl logs -n cockroach-operator-system deployment/cockroach-operator-manager

# Common issues:
# - ImagePullBackOff: Check internet connectivity
# - Pending: Check node resources
```

### CRD Not Installed

```bash
# Check if CRD exists
kubectl get crd crdbclusters.crdb.cockroachlabs.com

# If missing, reinstall operator
kubectl delete -f https://raw.githubusercontent.com/cockroachdb/cockroach-operator/v${COCKROACHDB_OPERATOR_VERSION}/install/operator.yaml
kubectl delete -f https://raw.githubusercontent.com/cockroachdb/cockroach-operator/v${COCKROACHDB_OPERATOR_VERSION}/install/crds.yaml
./setup.sh
```

### Operator Webhook Issues

```bash
# Check webhook configuration
kubectl get validatingwebhookconfigurations | grep cockroach
kubectl get mutatingwebhookconfigurations | grep cockroach

# Operator creates webhooks for CRD validation
# If cert-manager issues, operator may fail to start
```

## Teardown

```bash
cd ../..
./teardown.sh --phase 3
```

This will remove:
- CockroachDB Operator deployment
- Operator namespace
- CRDs (if no clusters exist)
- CockroachDB namespace (if empty)

**Note**: If CockroachDB clusters exist, teardown will fail safely to prevent data loss.

## Next Steps

Proceed to Phase 4: CockroachDB Cluster Deployment
- Deploy 3-node CockroachDB cluster
- Configure TLS with Vault-issued certificates
- Set up services for internal/external access
- Initialize database and create users
