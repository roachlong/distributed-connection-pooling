# AWS EKS Reference Architecture

Production-ready deployment of CockroachDB with distributed connection pooling, full data access controls (Row-Level Security, JWT authentication), and disaster recovery on AWS EKS using the CockroachDB Kubernetes Operator.

**Deployment Target**: Commercial AWS (us-east-2 primary, us-west-2 standby for PCR)

## Quick Links

- **[Architecture Overview](./ARCHITECTURE.md)** - Complete system architecture and design decisions
- **[Full Deployment Guide](./DEPLOYMENT.md)** - Step-by-step setup instructions for all phases
- **[Kubernetes Manifests](./manifests/)** - Phase-organized YAML configurations
- **[Configuration Reference](./config.env)** - Environment variables and pool sizing

## Overview

This reference architecture demonstrates a production-ready distributed connection pooling deployment with comprehensive data access controls, including:

**Security & Access Control:**
- JWT authentication via Okta OIDC with group-based role mapping
- Row-Level Security (RLS) with role-to-party access mapping
- Three dedicated PgBouncer connection pools (app 50%, batch 40%, admin 10%)
- Istio service mesh for JWT validation at ingress
- Client certificate authentication for service accounts
- Network policies for zero-trust networking

**Infrastructure:**
- Kubernetes-native deployment using CockroachDB Operator
- Automated cluster lifecycle management (scaling, upgrades, failover)
- Transaction pooling with identity propagation (SET LOCAL session variables)
- HashiCorp Vault PKI for certificate management (cert-manager integration)
- Multi-AZ deployment for high availability (3 availability zones)

**Operations:**
- Flyway schema migrations with sample-data-pipeline integration
- Prometheus + Grafana observability stack
- Audit logging to S3 with Object Lock (7-year retention)
- Physical Cluster Replication (PCR) for disaster recovery
- GitOps-based deployment workflow (optional)

**Compared to EC2 Architecture:**
- Kubernetes abstractions replace EC2 instance management
- CockroachDB Operator automates cluster operations
- Transaction pooling supports per-user identity (RLS-compatible)
- Istio ingress replaces custom auth gateway
- kubectl administration replaces SSH bastion hosts
- Container-based deployment with immutable infrastructure

## Prerequisites

- **AWS Account**: Commercial AWS with permissions for EKS, VPCs, S3, IAM, KMS
- **CLI Tools**: kubectl, helm, eksctl, aws CLI, istioctl, argocd (Phase 14 only)
- **Okta Tenant**: Admin access to configure OIDC application and security groups
- **HashiCorp Vault**: For PKI certificate management (deployed in Phase 2)
- **CockroachDB Enterprise License**: For encryption-at-rest, backups, and PCR (Phase 9+)
- **Kubernetes Knowledge**: Basic familiarity with pods, services, deployments, configmaps

## Getting Started

See the [Deployment Guide](./DEPLOYMENT.md) for complete setup instructions.

## Directory Structure

```
kubernetes/eks/
├── ARCHITECTURE.md           # System architecture, RLS design, connection pooling strategy
├── DEPLOYMENT.md             # Complete deployment guide (all 13 phases)
├── README.md                 # This file
├── config.env                # Environment variables, pool sizing, Okta config
├── teardown.sh               # Automated cleanup script
├── manifests/                # Kubernetes YAML manifests (organized by phase)
│   ├── phase1-foundation/    # EKS cluster, VPC, node groups
│   ├── phase2-certificates/  # Vault PKI for certificate authority
│   ├── phase3-operator/      # CockroachDB Operator, cert-manager
│   ├── phase4-cluster/       # CockroachDB cluster, JWT auth, roles, RLS
│   ├── phase5-pgbouncer/     # Three PgBouncer pools (app, batch, admin)
│   ├── phase6-istio/         # Istio service mesh for JWT validation
│   ├── phase7-flyway/        # Flyway schema migrations, RLS policies
│   ├── phase8-nifi/          # Apache NiFi cluster, ZooKeeper, Kafka, Registry
│   ├── phase9-enterprise/    # Enterprise license, encryption, backups
│   ├── phase10-observability/ # Prometheus, Grafana, alerting
│   ├── phase11-security/     # Network policies, IRSA, pod security
│   ├── phase12-audit/        # Audit logging to S3 with Object Lock
│   ├── phase13-pcr/          # Physical Cluster Replication (West standby)
│   └── phase14-gitops/       # ArgoCD GitOps workflow (optional)
└── generated/                # Generated manifests, reference documentation
    └── references/           # Connectivity guide, RLS design docs
```

## Implementation Plan

This reference architecture is built incrementally over 14 phases, where each phase is independently testable before moving to the next. This approach allows for incremental validation and troubleshooting.

### Phase Overview

| Phase | Component | Duration | Prerequisites |
|-------|-----------|----------|---------------|
| **0** | [Okta Configuration](#phase-0-okta-configuration) | 1h | Okta tenant admin |
| **1** | [EKS Cluster](#phase-1-eks-cluster) | 2-4h | AWS credentials, Phase 0 |
| **2** | [Vault PKI](#phase-2-vault-pki) | 2-3h | Phase 1 |
| **3** | [CockroachDB Operator](#phase-3-cockroachdb-operator) | 1h | Phase 2 |
| **4** | [CockroachDB Cluster](#phase-4-cockroachdb-cluster) | 2-3h | Phase 3, Okta config |
| **5** | [PgBouncer Pools](#phase-5-pgbouncer-connection-pools) | 2-3h | Phase 4 |
| **6** | [Istio Service Mesh](#phase-6-istio-service-mesh) | 1-2h | Phase 5 |
| **7** | [Flyway Migrations](#phase-7-flyway-schema-migrations) | 1-2h | Phase 6, sample-data-pipeline |
| **8** | [Enterprise Features](#phase-9-enterprise-features) | 1-2h | Phase 7, Enterprise license |
| **9** | [Observability Stack](#phase-10-observability-stack) | 2-3h | Phase 9 |
| **10** | [Security Hardening](#phase-11-security-hardening) | 2-3h | Phase 10 |
| **11** | [Audit Logging](#phase-12-audit-logging) | 2-3h | Phase 11 |
| **12** | [PCR (Disaster Recovery)](#phase-13-physical-cluster-replication-pcr) | 4-6h | Phase 12, West region |
| **13** | [GitOps](#phase-14-gitops-optional) _(optional)_ | 2-4h | Phase 13 |

**Total Estimated Time**: 25-40 hours (excludes optional Phase 14)

---

### Phase-by-Phase Summary

For complete instructions, validation steps, and troubleshooting, see [DEPLOYMENT.md](./DEPLOYMENT.md).

#### Phase 0: Okta Configuration
**Manual setup** of Okta OIDC application, security groups, and JWKS endpoint. Required for JWT authentication in Phase 4.

#### Phase 1: EKS Cluster
Deploy EKS cluster in us-east-2 with 3-AZ node groups, VPC, and storage classes.

#### Phase 2: Vault PKI
Deploy HashiCorp Vault as certificate authority with PKI secrets engine for CockroachDB and PgBouncer certificates.

#### Phase 3: CockroachDB Operator
Install CockroachDB Kubernetes Operator and cert-manager for automated certificate management.

#### Phase 4: CockroachDB Cluster
Deploy 3-node CockroachDB cluster with:
- JWT authentication (Okta JWKS integration)
- Role hierarchy (parent roles + Okta-mapped roles)
- Service account users (pgb_app_user, pgb_batch_user, pgb_admin_user, flyway_svc)
- Three databases (metadata, staging, production)
- Example RLS configuration

#### Phase 5: PgBouncer Connection Pools
Deploy three dedicated PgBouncer pools with separate service accounts:
- **App pool** (50%, port 5432): RLS-enforced user connections
- **Batch pool** (40%, port 5433): Batch jobs with BYPASSRLS
- **Admin pool** (10%, port 5434): DBA operations

Each pool uses transaction pooling with identity propagation via SET LOCAL session variables.

#### Phase 6: Istio Service Mesh
Deploy Istio for JWT validation at ingress gateway:
- RequestAuthentication resource (validates Okta JWT tokens)
- AuthorizationPolicy (requires valid JWT)
- Sidecar injection on cockroachdb namespace

#### Phase 7: Flyway Schema Migrations
Deploy Flyway for automated schema migrations:
- Copy SQL scripts from sample-data-pipeline repository
- Add custom RLS scripts (role_party_access table, RLS policies)
- Flyway connects directly to CockroachDB:26257 (bypasses PgBouncer)

#### Phase 8: Apache NiFi Data Flow Platform
Deploy multi-node NiFi 2.x cluster as the data flow and ETL orchestration layer:
- 3-node NiFi StatefulSet with dedicated r6i.4xlarge node group
- ZooKeeper 3-node StatefulSet for cluster coordination
- Kafka 3-broker StatefulSet for event streaming
- NiFi Registry with Git-backed flow versioning
- cert-manager TLS for all nodes, Istio passthrough for NiFi ports
- CockroachDB JDBC via PgBouncer batch pool (port 5433, BYPASSRLS)

#### Phase 9: Enterprise Features
Enable Enterprise features with license:
- S3 backups with IRSA (automated full + incremental)
- Encryption-at-rest with customer-managed keys
- Changefeeds for audit events

#### Phase 10: Observability Stack
Deploy Prometheus + Grafana monitoring:
- ServiceMonitor for CockroachDB metrics
- PgBouncer exporter for pool statistics
- Pre-configured Grafana dashboards
- Alert rules for cluster health

#### Phase 11: Security Hardening
Apply security best practices:
- NetworkPolicies (deny-all default, explicit allow rules)
- Pod Security Standards (restricted)
- IRSA for S3 access (no hardcoded credentials)
- Certificate rotation (90-day TTL)

#### Phase 12: Audit Logging
Deploy audit log pipeline to S3:
- Enable CockroachDB audit logging (all SQL statements, auth events)
- Fluent Bit DaemonSet for log collection
- S3 bucket with Object Lock (7-year retention)
- Optional Athena table for querying

#### Phase 13: Physical Cluster Replication (PCR)
Deploy West standby cluster for disaster recovery:
- Second EKS cluster in us-west-2
- Physical replication from East (primary) to West (standby)
- Analytics PgBouncer pool on West (100% of West capacity)
- Automated failover scripts (manual invocation)

#### Phase 14: GitOps (Optional)
Migrate to ArgoCD-based deployment workflow:
- ArgoCD installation in both clusters
- Application definitions for all phases
- Auto-sync and self-healing
- Git-driven infrastructure changes

---

## Teardown / Cleanup

Use the automated teardown script to remove deployed resources and avoid ongoing AWS costs.

### Usage

```bash
cd kubernetes/eks

# Delete a specific phase only
./teardown.sh --phase 7

# Delete from Phase N down to Phase 1 (reverse order)
./teardown.sh --from-phase 7

# Delete all phases (13 through 1)
./teardown.sh --all
```

### Common Scenarios

**After testing Phase 7 (Flyway)**:
```bash
./teardown.sh --from-phase 7
# Deletes: Phases 7, 6, 5, 4, 3, 2, 1 in reverse order
```

**Complete teardown (all phases)**:
```bash
./teardown.sh --all
# Deletes: All phases 14 through 1
```

**Delete only observability stack (Phase 10)**:
```bash
./teardown.sh --phase 9
# Deletes: Phase 10 only (Prometheus, Grafana, Alertmanager)
```

### What Gets Deleted (by phase)

The script automatically removes (in reverse order):

- **Phase 14**: ArgoCD installation, Application definitions, GitOps workflow
- **Phase 13**: West EKS cluster, PCR replication streams, analytics pool
- **Phase 12**: Fluent Bit DaemonSet, S3 audit bucket with Object Lock
- **Phase 11**: NetworkPolicies, Pod Security Standards, IRSA configurations
- **Phase 10**: Prometheus, Grafana, Alertmanager, ServiceMonitors
- **Phase 9**: S3 backup bucket, Enterprise license configuration, encryption keys
- **Phase 8**: NiFi cluster, ZooKeeper, Kafka, NiFi Registry, all PVCs, nifi namespace
- **Phase 7**: Flyway Jobs, migration ConfigMaps, RLS scripts
- **Phase 6**: Istio control plane, ingress gateway, RequestAuthentication, AuthorizationPolicy
- **Phase 5**: Three PgBouncer pools (app/batch/admin), services, certificates
- **Phase 4**: CockroachDB cluster, databases, roles, service accounts, JWT configuration
- **Phase 3**: CockroachDB Operator, cert-manager, CRDs
- **Phase 2**: Vault StatefulSet, PKI secrets engine
- **Phase 1**: EKS cluster, VPC, node groups

### Important Notes

**Safety Features**:
- Interactive confirmation prompts before deletion
- Loads configuration from `config.env` automatically
- Phases deleted in reverse dependency order
- Clear status output with color-coded messages

**EKS Cluster Deletion (Phase 1)**:
- `eksctl delete cluster` automatically deletes all Kubernetes resources
- Takes 10-15 minutes to complete
- EBS volumes with `reclaimPolicy: Retain` persist (default for safety)

**S3 Object Lock (Phase 12)**:
- Audit log objects with Object Lock cannot be deleted until 7-year retention expires
- For testing: Use `Governance` mode (not `Compliance`) to allow admin override
- The script will skip locked objects and warn about retention

**Cost Awareness**:
- **EKS control plane**: ~$0.10/hour (~$73/month) per cluster
- **EC2 nodes**: m5.2xlarge ~$0.384/hour × node count
- **NAT Gateway**: ~$0.045/hour (~$32/month) per AZ
- **EBS volumes**: ~$0.10/GB-month
- **S3 storage**: ~$0.023/GB-month (Standard) + request costs
- **Always delete test clusters** to avoid ongoing costs

**Verify Cleanup**:

After teardown, check for orphaned resources:

```bash
# Check for remaining EKS clusters
aws eks list-clusters --region us-east-2
aws eks list-clusters --region us-west-2  # If Phase 13 was deployed

# Check for orphaned VPCs
aws ec2 describe-vpcs --region us-east-2 --filters "Name=tag:Name,Values=example-crdb-*"

# Check for orphaned Load Balancers
aws elbv2 describe-load-balancers --region us-east-2 | jq '.LoadBalancers[] | select(.LoadBalancerName | contains("example-crdb"))'

# Check for orphaned EBS volumes
aws ec2 describe-volumes --region us-east-2 --filters "Name=tag:kubernetes.io/cluster/example-crdb-eks,Values=owned"

# Check for remaining S3 buckets
aws s3 ls | grep example-crdb
```

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

**Documentation Phase**: All architecture and deployment documentation complete. Ready to begin implementation.

- [x] Phase 0: Okta Configuration - **Manual setup documented**
- [x] Phase 1: EKS Cluster - **Deployed, tested**
- [x] Phase 2: Vault PKI - **Deployed, tested**
- [x] Phase 3: CockroachDB Operator - **Deployed, tested**
- [x] Phase 4: CockroachDB Cluster - **Deployed, ready for JWT/roles/RLS updates**
- [x] Phase 5: PgBouncer - **Single pool deployed, ready for three-pool refactor**
- [ ] Phase 6: Istio Service Mesh - **Documentation complete**
- [ ] Phase 7: Flyway Schema Migrations - **Documentation complete**
- [ ] Phase 8: Apache NiFi Data Flow Platform - **Architecture documented, implementation pending**
- [ ] Phase 9: Enterprise Features - **Documentation complete**
- [ ] Phase 10: Observability Stack - **Documentation complete**
- [ ] Phase 11: Security Hardening - **Documentation complete**
- [ ] Phase 12: Audit Logging - **Documentation complete**
- [ ] Phase 13: Physical Cluster Replication - **Documentation complete**
- [ ] Phase 14: GitOps (optional) - **Documentation complete**

**Next**: Complete Phases 6 (Istio) and 7 (Flyway), then implement Phase 8 (NiFi) data flow platform.

See [ARCHITECTURE.md](./ARCHITECTURE.md) for complete design and [DEPLOYMENT.md](./DEPLOYMENT.md) for step-by-step instructions.
