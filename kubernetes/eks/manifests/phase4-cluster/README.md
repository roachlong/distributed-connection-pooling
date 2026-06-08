## Phase 4: CockroachDB Cluster

Deploys a 3-node CockroachDB cluster using the CockroachDB Operator with TLS certificates from Vault.

## What's Deployed

**CockroachDB Cluster:**
- 3-node CockroachDB StatefulSet (one pod per AZ)
- PersistentVolumeClaims (100Gi gp3 encrypted with KMS)
- TLS enabled with Vault-issued certificates via cert-manager
- Services for SQL and Admin UI access

**Certificates:**
- Node certificates (for inter-node communication)
- Client certificates (for SQL client authentication)
- Automatically managed by cert-manager + Vault PKI

**Services:**
- `cockroachdb-east-public` - SQL access (port 26257) and Admin UI (port 8080)
- `cockroachdb-east` - Headless service for StatefulSet

## Prerequisites

- Phase 1 complete (EKS cluster with gp3 encrypted StorageClass)
- Phase 2 complete (Vault + cert-manager with vault-issuer)
- Phase 3 complete (CockroachDB Operator installed)
- kubectl installed

## Deployment

```bash
cd manifests/phase4-cluster
./setup.sh
```

The script will:
1. Create Certificate resources (cert-manager generates secrets via Vault)
2. Wait for certificates to be ready
3. Deploy CrdbCluster custom resource
4. Wait for all 3 pods to be running
5. Initialize the cluster (one-time setup)
6. Create SQL users and databases
7. Display connection information

## Validation

```bash
# Check CrdbCluster status
kubectl get crdbcluster -n cockroachdb

# Check CockroachDB pods
kubectl get pods -n cockroachdb

# Check certificates
kubectl get certificate -n cockroachdb

# Check services
kubectl get svc -n cockroachdb

# Check PVCs
kubectl get pvc -n cockroachdb

# View cluster info
kubectl exec -n cockroachdb cockroachdb-east-0 -- ./cockroach node status --certs-dir=/cockroach/cockroach-certs
```

## Expected Output

```bash
# CrdbCluster should show Running
NAME               NODES   VERSION
cockroachdb-east   3       v25.4.11

# All 3 pods should be Running
NAME            READY   STATUS    RESTARTS   AGE
cockroachdb-ease-0   1/1     Running   0          5m
cockroachdb-east-1   1/1     Running   0          4m
cockroachdb-east-2   1/1     Running   0          3m

# Certificates should be Ready
NAME                      READY   SECRET                    AGE
cockroachdb-node          True    cockroachdb-node          5m
cockroachdb-client-root   True    cockroachdb-client-root   5m

# Services should exist
NAME                      TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)
cockroachdb-east          ClusterIP   None             <none>        26258/TCP,8080/TCP,26257/TCP
cockroachdb-east-public   ClusterIP   172.20.xxx.xxx   <none>        26258/TCP,8080/TCP,26257/TCP
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  cockroachdb namespace                                       │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  CrdbCluster: cockroachdb-east                         │ │
│  │  - nodes: 3                                            │ │
│  │  - tlsEnabled: true                                    │ │
│  │  - nodeTLSSecret: cockroachdb-node                     │ │
│  │  - clientTLSSecret: cockroachdb-client-root            │ │
│  └────────────────────────────────────────────────────────┘ │
│                      │                                       │
│                      │ creates                               │
│                      ▼                                       │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  StatefulSet: cockroachdb-east                         │ │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐      │ │
│  │  │ Pod 0 (AZ-a)│ │ Pod 1 (AZ-b)│ │ Pod 2 (AZ-c)│      │ │
│  │  │ PVC: 100Gi  │ │ PVC: 100Gi  │ │ PVC: 100Gi  │      │ │
│  │  └─────────────┘ └─────────────┘ └─────────────┘      │ │
│  └────────────────────────────────────────────────────────┘ │
│                      ▲                                       │
│                      │ mounted secrets                       │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Certificates (cert-manager + Vault)                   │ │
│  │  ┌──────────────────┐  ┌────────────────────────────┐ │ │
│  │  │ cockroachdb-node │  │ cockroachdb-client-root    │ │ │
│  │  │ (node TLS)       │  │ (SQL client TLS)           │ │ │
│  │  └──────────────────┘  └────────────────────────────┘ │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## Configuration

Key settings from config.env:
- **Version**: `${COCKROACHDB_VERSION}` (v25.4.11)
- **Nodes**: 3 (one per availability zone)
- **CPU**: 4 cores request, 8 cores limit
- **Memory**: 16Gi request, 32Gi limit
- **Storage**: 100Gi per node (gp3, 16000 IOPS, 1000 MB/s throughput)
- **StorageClass**: crdb-gp3-encrypted (KMS encrypted)
- **TLS**: Enabled (Vault-issued certificates)

## Connecting to the Cluster

### From within Kubernetes

```bash
# SQL client (requires client certificate)
kubectl exec -it -n cockroachdb cockroachdb-east-0 -- ./cockroach sql --certs-dir=/cockroach/cockroach-certs

# One-liner SQL query
kubectl exec -n cockroachdb cockroachdb-east-0 -- ./cockroach sql --certs-dir=/cockroach/cockroach-certs --execute="SHOW DATABASES;"
```

### Admin UI

Forward the Admin UI port:
```bash
kubectl port-forward -n cockroachdb svc/cockroachdb-east-public 8080:8080
```

Then access: http://localhost:8080

If port 8080 is already in use locally:
```bash
kubectl port-forward -n cockroachdb svc/cockroachdb-east-public 8090:8080
```

Then access: http://localhost:8090

## Troubleshooting

### Pods Not Starting

```bash
# Check pod events
kubectl describe pod cockroachdb-east-0 -n cockroachdb

# Check operator logs
kubectl logs -n cockroach-operator-system deployment/cockroach-operator-manager

# Common issues:
# - PVC pending: Check StorageClass and EBS CSI driver
# - Image pull errors: Check COCKROACHDB_VERSION in config.env
# - Certificate errors: Check cert-manager and Vault issuer
```

### Certificates Not Ready

```bash
# Check certificate status
kubectl describe certificate cockroachdb-node -n cockroachdb
kubectl describe certificate cockroachdb-client-root -n cockroachdb

# Check cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager

# Verify vault-issuer is ready
kubectl get clusterissuer vault-issuer
```

### Cluster Initialization Failed

```bash
# Check if cluster is already initialized
kubectl exec -n cockroachdb cockroachdb-east-0 -- ./cockroach node status --certs-dir=/cockroach/cockroach-certs

# If cluster is in inconsistent state, may need to recreate
kubectl delete crdbcluster cockroachdb-east -n cockroachdb
kubectl delete pvc -n cockroachdb --all
./setup.sh
```

### Storage Issues

```bash
# Check PVC status
kubectl get pvc -n cockroachdb
kubectl describe pvc datadir-cockroachdb-east-0 -n cockroachdb

# Check StorageClass
kubectl get storageclass crdb-gp3-encrypted -o yaml

# Verify EBS CSI driver
kubectl get pods -n kube-system | grep ebs-csi
```

## Teardown

```bash
cd ../..
./teardown.sh --phase 4
```

This will remove:
- CrdbCluster resource (operator deletes StatefulSet and Services)
- Certificates
- Secrets
- PVCs (if reclaimPolicy is Delete) or orphaned volumes cleaned by teardown script

**Note**: With `reclaimPolicy: Retain`, volumes are preserved for data recovery. The teardown script will clean up orphaned volumes.

## Next Steps

Proceed to Phase 5: Connection Pooling (PgBouncer)
- Deploy PgBouncer for connection pooling
- Configure connection limits and pool modes
- Set up monitoring and metrics
- Load testing and performance tuning

## Sources

- [CockroachDB Operator example.yaml](https://github.com/cockroachdb/cockroach-operator/blob/master/examples/example.yaml)
- [Certificate Management with the CockroachDB Operator](https://www.cockroachlabs.com/docs/stable/secure-cockroachdb-operator)
- [Deploy CockroachDB with the CockroachDB Operator](https://www.cockroachlabs.com/docs/stable/deploy-cockroachdb-with-cockroachdb-operator)
