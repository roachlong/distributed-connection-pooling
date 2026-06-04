# AWS EKS Reference Architecture

Production-ready deployment of CockroachDB with distributed connection pooling on AWS EKS using the CockroachDB Kubernetes Operator.

**Deployment Targets**: Commercial AWS (default) and AWS GovCloud — migration between clouds requires only changing variables in [config.env](config.env).

## Quick Links

- **[Full Deployment Guide](./DEPLOYMENT.md)** - Complete setup instructions
- **[Kubernetes Manifests](./manifests/)** - YAML configurations (coming soon)
- **[Helm Charts](./helm/)** - Helm-based deployments (coming soon)

## Overview

This reference architecture demonstrates how to deploy a highly available, cloud-native CockroachDB cluster with PgBouncer connection pooling on AWS EKS.

**Key Features:**
- Kubernetes-native deployment using CockroachDB Operator
- Automated cluster lifecycle management (scaling, upgrades, failover)
- PgBouncer for connection pooling
- AWS Network Load Balancer for external access
- EBS encryption + CockroachDB encryption-at-rest
- IRSA for secure S3 backup access
- Multi-AZ deployment for high availability

**Compared to EC2 Architecture:**
- Simpler operational model with Kubernetes abstractions
- Automated cluster management via operator
- Container-based deployment instead of VMs
- Kubernetes Services instead of HAProxy + Keepalived
- kubectl-based administration instead of SSH

## Prerequisites

- AWS account with EKS permissions (commercial AWS or GovCloud)
- kubectl, helm, eksctl, aws CLI installed
- Basic Kubernetes knowledge
- HashiCorp Vault instance (for PKI/certificate management)
- CockroachDB Enterprise license (for encryption-at-rest and PCR)

## Getting Started

See the [Deployment Guide](./DEPLOYMENT.md) for complete setup instructions.

## Directory Structure

```
kubernetes/eks/
├── DEPLOYMENT.md          # Complete deployment guide
├── README.md              # This file
├── manifests/             # Kubernetes YAML manifests (organized by phase)
│   ├── phase1-foundation/
│   ├── phase2-certificates/
│   ├── phase3-operator/
│   ├── phase4-crdb-cluster/
│   ├── phase5-pgbouncer/
│   ├── phase6-enterprise/
│   ├── phase7-observability/
│   ├── phase8-security/
│   ├── phase9-audit/
│   └── phase10-pcr/
└── helm/                  # Helm chart (coming soon)
    └── dcp-crdb/
```

## Implementation Plan

This reference architecture is built incrementally over 10 phases, where each phase is independently testable before moving to the next. This approach allows for incremental validation and troubleshooting.

### Phase Overview

| Phase | Component | Duration | Prerequisites |
|-------|-----------|----------|---------------|
| **1** | [Foundation](#phase-1-foundation) | 2-4h | AWS creds |
| **2** | [Certificates](#phase-2-certificates) | 2-3h | Phase 1, Vault |
| **3** | [Operator](#phase-3-operator) | 1h | Phase 2 |
| **4** | [CRDB Cluster](#phase-4-crdb-cluster) | 2-3h | Phase 3 |
| **5** | [PgBouncer](#phase-5-pgbouncer) | 1-2h | Phase 4 |
| **6** | [Enterprise](#phase-6-enterprise) | 1-2h | Phase 5, License |
| **7** | [Observability](#phase-7-observability) | 2-3h | Phase 6 |
| **8** | [Security](#phase-8-security) | 2-3h | Phase 7 |
| **9** | [Audit](#phase-9-audit) | 2-3h | Phase 8 |
| **10** | [PCR](#phase-10-pcr) | 4-6h | Phase 9, Transit GW |
| **11** | [GitOps](#phase-11-gitops-optional) _(optional)_ | 2-4h | Phase 10 |

**Total Estimated Time**: 21-34 hours

---

### Phase 1: Foundation

**Objective**: Deploy EKS cluster in primary region with 3-AZ topology

**Steps**:
1. Configure variables in config.env (regions, instance types, etc.)
2. Mirror container images to ECR (GovCloud only - skip for commercial AWS)
3. Create customer-managed KMS key for EBS encryption
4. Create S3 buckets (backups + audit logs) with Object Lock
5. Deploy EKS cluster with 3 node groups (one per AZ)
6. Install AWS Load Balancer Controller
7. Create StorageClass with `volumeBindingMode: WaitForFirstConsumer`

**Success Criteria**:
- ✅ 3 node groups running (one per AZ in primary region)
- ✅ StorageClass with CMK encryption ready
- ✅ LB controller operational

**Key Manifests**:
- `manifests/phase1-foundation/cluster-east.yaml` (eksctl config)
- `manifests/phase1-foundation/storageclass.yaml`

---

### Phase 2: Certificates

**Objective**: Deploy cert-manager with Vault PKI integration

**Steps**:
1. Configure Vault PKI secrets engine and root CA
2. Create PKI roles for CockroachDB (node + client certs)
3. Configure Kubernetes auth in Vault
4. Deploy cert-manager via Helm
5. Create Vault ClusterIssuer

**Success Criteria**:
- ✅ cert-manager pods running
- ✅ Vault ClusterIssuer ready
- ✅ Test certificate issued successfully

**Key Manifests**:
- `manifests/phase2-certificates/cert-manager-values.yaml`
- `manifests/phase2-certificates/vault-issuer.yaml`

---

### Phase 3: Operator

**Objective**: Install CockroachDB Kubernetes Operator

**Steps**:
1. Create cockroach-operator-system namespace
2. Apply CockroachDB CRDs
3. Deploy operator

**Success Criteria**:
- ✅ CRDs installed
- ✅ Operator pod running without errors

**Key Manifests**:
- `manifests/phase3-operator/operator.yaml`

---

### Phase 4: CRDB Cluster

**Objective**: Deploy 3-node CockroachDB cluster with mTLS

**Steps**:
1. Create cockroachdb namespace
2. Create Certificate resources (node + client)
3. Create CrdbCluster CR with 3-AZ anti-affinity
4. Verify cluster initialization

**Success Criteria**:
- ✅ 3 pods running (one per AZ)
- ✅ Cluster healthy, SQL accessible
- ✅ Certificates issued by cert-manager

**Key Manifests**:
- `manifests/phase4-crdb-cluster/crdb-east.yaml`
- `manifests/phase4-crdb-cluster/certificates.yaml`

---

### Phase 5: PgBouncer

**Objective**: Deploy connection pooling and expose via NLB

**Steps**:
1. Create PgBouncer client certificate
2. Create ConfigMap (transaction pooling, cert auth)
3. Deploy PgBouncer (3 replicas)
4. Create Service (internal NLB)

**Success Criteria**:
- ✅ PgBouncer pods running
- ✅ NLB provisioned
- ✅ Can connect to CRDB through PgBouncer

**Key Manifests**:
- `manifests/phase5-pgbouncer/pgbouncer-deployment.yaml`
- `manifests/phase5-pgbouncer/pgbouncer-service.yaml`

---

### Phase 6: Enterprise

**Objective**: Apply Enterprise license and enable encryption-at-rest

**Steps**:
1. Deploy External Secrets Operator
2. Store license in Vault KV
3. Create ExternalSecret for license
4. Apply license via SQL
5. Generate encryption key
6. Update CrdbCluster CR for encryption-at-rest

**Success Criteria**:
- ✅ License active
- ✅ Encryption enabled (verify with `cockroach debug encryption-active-key`)

**Key Manifests**:
- `manifests/phase6-enterprise/license-external-secret.yaml`
- `manifests/phase6-enterprise/crdb-east-encrypted.yaml`

---

### Phase 7: Observability

**Objective**: Deploy Prometheus + Grafana monitoring

**Steps**:
1. Deploy kube-prometheus-stack
2. Create ServiceMonitor for CRDB metrics
3. Import Grafana dashboards
4. Configure alerts

**Success Criteria**:
- ✅ Prometheus showing CRDB targets UP
- ✅ Grafana dashboards populated

**Key Manifests**:
- `manifests/phase7-observability/crdb-servicemonitor.yaml`
- `manifests/phase7-observability/prometheus-rules.yaml`

---

### Phase 8: Security

**Objective**: Network policies and IRSA for S3

**Steps**:
1. Create IRSA for S3 backup access
2. Deploy deny-all NetworkPolicy
3. Deploy allow NetworkPolicies (CRDB ↔ PgBouncer, monitoring)
4. Test S3 backup via IRSA

**Success Criteria**:
- ✅ Network policies enforced
- ✅ S3 backup succeeds with IRSA
- ✅ Internet egress blocked (except S3, DNS)

**Key Manifests**:
- `manifests/phase8-security/network-policy-deny-all.yaml`
- `manifests/phase8-security/network-policy-crdb-*.yaml`

---

### Phase 9: Audit

**Objective**: Stream audit logs to S3 with Object Lock

**Steps**:
1. Enable SENSITIVE_ACCESS audit logging in CRDB
2. Create IRSA for Fluent Bit
3. Deploy Fluent Bit DaemonSet
4. Verify logs in S3 with 7-year retention

**Success Criteria**:
- ✅ Audit logs flowing to S3
- ✅ Object Lock verified (7-year WORM)

**Key Manifests**:
- `manifests/phase9-audit/fluent-bit-daemonset.yaml`

---

### Phase 10: PCR

**Objective**: Add West cluster and configure active-passive PCR

**Steps**:
1. Repeat Phases 1-9 for secondary region (us-west-2 commercial / us-gov-west-1 GovCloud)
2. Configure Transit Gateway between East/West VPCs
3. Enable rangefeed on both clusters
4. Create virtual cluster replication (East → West)
5. Test failover and failback

**Success Criteria**:
- ✅ West cluster healthy
- ✅ PCR replication lag < 10s
- ✅ Failover tested successfully

**Key Manifests**:
- `manifests/phase10-pcr/cluster-west.yaml`
- `manifests/phase10-pcr/crdb-west.yaml`

---

### Phase 11: GitOps (Optional)

**Objective**: Migrate to ArgoCD-based GitOps workflow

**Steps**:
1. Install ArgoCD in both clusters
2. Organize manifests in Git repository
3. Create ArgoCD Applications
4. Test Git-based deployment workflow

**Success Criteria**:
- ✅ All components managed by ArgoCD
- ✅ Changes flow through Git PR → sync

---

### Testing Strategy

**After each phase**:
1. Run validation tests from that phase
2. Run smoke tests (verify previous phases still work)
3. Commit manifests to Git with tag (e.g., `phase-4-complete`)

**Smoke Test**:
```bash
# Cluster health
kubectl get nodes
kubectl get pods -n cockroachdb

# CRDB connectivity
kubectl exec -it cockroachdb-east-0 -n cockroachdb -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost -e "SELECT 1;"

# PgBouncer connectivity (after Phase 5)
kubectl run -it --rm psql --image=postgres:15 --restart=Never -- \
  psql "postgresql://root@pgbouncer.cockroachdb.svc.cluster.local:5432/defaultdb?sslmode=require" -c "SELECT 1;"
```

### Rollback Strategy

If a phase fails:
1. Document error and logs
2. Roll back to previous phase Git tag
3. Troubleshoot in isolation (see DEPLOYMENT.md Troubleshooting)
4. Re-attempt phase after fix

---

## Current Status

- [ ] Phase 1: Foundation
- [ ] Phase 2: Certificates
- [ ] Phase 3: Operator
- [ ] Phase 4: CRDB Cluster
- [ ] Phase 5: PgBouncer
- [ ] Phase 6: Enterprise
- [ ] Phase 7: Observability
- [ ] Phase 8: Security
- [ ] Phase 9: Audit
- [ ] Phase 10: PCR
- [ ] Phase 11: GitOps (optional)

**Next**: Start with Phase 1 - see [DEPLOYMENT.md](./DEPLOYMENT.md) for detailed instructions.
