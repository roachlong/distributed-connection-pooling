# Distributed Connection Pooling - EKS Deployment Guide

Complete step-by-step deployment guide for the distributed connection pooling reference architecture on AWS EKS with full data access controls, observability, security hardening, and disaster recovery.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Architecture Overview](#architecture-overview)
- [Phase 0: Okta Configuration](#phase-0-okta-configuration)
- [Phase 1: EKS Cluster](#phase-1-eks-cluster)
- [Phase 2: Vault PKI](#phase-2-vault-pki)
- [Phase 3: CockroachDB Operator](#phase-3-cockroachdb-operator)
- [Phase 4: CockroachDB Cluster](#phase-4-cockroachdb-cluster)
- [Phase 5: PgBouncer Connection Pools](#phase-5-pgbouncer-connection-pools)
- [Phase 6: Istio Service Mesh](#phase-6-istio-service-mesh)
- [Phase 7: Flyway Schema Migrations](#phase-7-flyway-schema-migrations)
- [Phase 8: Apache NiFi Data Flow Platform](#phase-8-apache-nifi-data-flow-platform)
- [Phase 9: Enterprise Features](#phase-9-enterprise-features)
- [Phase 10: Observability Stack](#phase-10-observability-stack)
- [Phase 11: Security Hardening](#phase-11-security-hardening)
- [Phase 12: Audit Logging](#phase-12-audit-logging)
- [Phase 13: Physical Cluster Replication (PCR)](#phase-13-physical-cluster-replication-pcr)
- [Phase 14: GitOps (Optional)](#phase-14-gitops-optional)
- [Post-Deployment Validation](#post-deployment-validation)
- [Troubleshooting](#troubleshooting)
- [Teardown](#teardown)

## Prerequisites

### Required Tools

Install the following tools on your local machine:

```bash
# AWS CLI v2
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /

# eksctl
brew install eksctl

# kubectl
brew install kubectl

# Helm
brew install helm

# jq (for JSON processing)
brew install jq

# envsubst (for template substitution)
brew install gettext

# istioctl (for Phase 6)
brew install istioctl

# ArgoCD CLI (for Phase 14, optional)
brew install argocd
```

### AWS Account Setup

1. **AWS Account Access**: Ensure you have AWS account credentials with permissions to create:
   - EKS clusters
   - VPCs, subnets, security groups
   - EC2 instances
   - IAM roles and policies
   - Load balancers
   - S3 buckets (for backups and audit logs)

2. **Configure AWS CLI**:
```bash
aws configure
# Enter your AWS Access Key ID
# Enter your AWS Secret Access Key
# Default region: us-east-2
# Default output format: json
```

3. **Verify AWS Access**:
```bash
aws sts get-caller-identity
```

### Okta Tenant

You'll need an Okta tenant with admin access to configure OIDC applications and groups. If you don't have one, sign up for a free developer account at https://developer.okta.com/.

### CockroachDB Enterprise License (Phase 9)

For enterprise features (backup/restore, encryption-at-rest, RBAC, changefeed), you'll need a CockroachDB Enterprise license. Request a trial license at https://www.cockroachlabs.com/get-started-cockroachdb/.

### Domain Name (Optional)

For production deployments, you may want a domain name for the Istio ingress gateway. For testing, you can use the auto-generated ELB DNS name.

## Architecture Overview

Before starting deployment, review the [ARCHITECTURE.md](./ARCHITECTURE.md) document to understand:

- Connection pooling strategy (50% app, 40% batch, 10% admin)
- Security model (client certificates + JWT authentication)
- Row-Level Security (RLS) design
- Database schema structure (metadata, staging, production)
- Component access patterns
- Observability and monitoring approach
- Disaster recovery with Physical Cluster Replication

### Phase Dependencies

```
Phase 0: Okta Configuration (Manual)
    ↓
Phase 1: EKS Cluster
    ↓
Phase 2: Vault PKI (Certificate Authority)
    ↓
Phase 3: CockroachDB Operator
    ↓
Phase 4: CockroachDB Cluster (JWT, Roles, Service Accounts, RLS)
    ↓
Phase 5: PgBouncer (Three Pools: app, batch, admin)
    ↓
Phase 6: Istio Service Mesh (JWT Validation)
    ↓
Phase 7: Flyway Schema Migrations
    ↓
Phase 8: Apache NiFi Data Flow Platform (ZooKeeper, Kafka, NiFi Cluster, Registry)
    ↓
Phase 9: Enterprise Features (License, Encryption, Backups)
    ↓
Phase 10: Observability Stack (Prometheus, Grafana, Alertmanager)
    ↓
Phase 11: Security Hardening (Network Policies, Pod Security, IRSA)
    ↓
Phase 12: Audit Logging (Fluent Bit, S3 Object Lock)
    ↓
Phase 13: Physical Cluster Replication (PCR West Standby)
    ↓
Phase 14: GitOps (ArgoCD, optional)
```

## Phase 0: Okta Configuration

Configure Okta OIDC application and groups for JWT-based authentication.

### Step 1: Create or Reuse OIDC Application

**Option A: Reuse Existing Application**
If you already have an Okta OIDC application configured (e.g., from okta-crdb-sync), you can reuse it. Just note the **Client ID** - you'll need it for `config.env`.

**Option B: Create New Application**
1. Log in to your Okta Admin Console
2. Navigate to **Applications** → **Applications**
3. Click **Create App Integration**
4. Select **OIDC - OpenID Connect**
5. Select **Web Application**
6. Configure:
   - **App integration name**: `CockroachDB Cluster` (or any name you prefer)
   - **Sign-in redirect URIs**: `https://localhost:8080/callback` (placeholder, not used for JWT validation)
   - **Sign-out redirect URIs**: `https://localhost:8080` (placeholder, not used for JWT validation)
   - **Controlled access**: Choose who can access (e.g., "Allow everyone in your organization to access")
7. Click **Save**
8. Note the **Client ID** - you'll need it for `config.env`

### Step 2: Configure Token Settings

1. In the application, go to **Sign On** tab
2. Click **Edit** in the OpenID Connect ID Token section
3. Configure:
   - **Issuer**: Use Okta URL (recommended)
   - **Audience**: Use the **Client ID** from Step 1, or a custom value (must match `OKTA_AUDIENCE` in config.env)
4. Click **Save**

### Step 3: Add Groups Claim

1. Still in the application, go to **Sign On** tab
2. Scroll to **OpenID Connect ID Token**
3. Add a **Groups** claim:
   - **Name**: `groups`
   - **Include in**: ID Token, Always
   - **Filter**: Starts with `crdb_`
4. Click **Save**

### Step 4: Create Security Groups

Create the following groups in Okta (navigate to **Directory** → **Groups** → **Add Group**):

| Group Name | Description |
|------------|-------------|
| `crdb_advisor_team_east` | Advisors in East region (full account access for East parties) |
| `crdb_advisor_team_west` | Advisors in West region (full account access for West parties) |
| `crdb_client_services` | Client services team (read-only access to accounts) |
| `crdb_compliance_team` | Compliance team (read-only access to compliance views) |
| `crdb_fiduciary_admin` | Fiduciary administrators (read-write access to all parties) |
| `crdb_batch_service` | Batch processing service accounts (BYPASSRLS) |
| `crdb_developers` | Developers (dev environment access) |

### Step 5: Assign Users to Groups

1. Navigate to **Directory** → **Groups**
2. For each group, click the group name
3. Click **Assign people**
4. Assign appropriate users to each group

### Step 6: Obtain JWKS URL

The JSON Web Key Set (JWKS) URL is used by CockroachDB to validate JWT tokens.

Format: `https://{your-okta-domain}/oauth2/default/v1/keys`

Example: `https://dev-12345678.okta.com/oauth2/default/v1/keys`

### Step 7: Update config.env

Update `config.env` with Okta configuration values:

```bash
# Edit config.env
vi config.env

# Add Okta configuration:
export OKTA_ISSUER="https://dev-12345678.okta.com/oauth2/default"
export OKTA_JWKS_URL="https://dev-12345678.okta.com/oauth2/default/v1/keys"
export OKTA_CLIENT_ID="0oa9abcd1234efgh5678"
export OKTA_AUDIENCE="example-crdb-cluster"
```

## Phase 1: EKS Cluster

Deploy the EKS cluster in us-east-2.

### Step 1: Review Configuration

```bash
cd /path/to/distributed-connection-pooling/kubernetes/eks
cat config.env
```

Verify the following settings:
- `AWS_REGION="us-east-2"`
- `EKS_CLUSTER_NAME` (default: your desired cluster name)
- `EKS_NODE_COUNT` and `EKS_INSTANCE_TYPE`

### Step 2: Run Phase 1 Setup

```bash
cd manifests/phase1-foundation
chmod +x setup.sh
./setup.sh
```

This will:
- Create VPC with public and private subnets across 3 availability zones
- Create EKS cluster with control plane (takes ~15-20 minutes)
- Create managed node group with specified instance types
- Configure kubectl context
- Enable IRSA (IAM Roles for Service Accounts)

### Step 3: Verify Cluster

```bash
kubectl cluster-info
kubectl get nodes
```

Expected output:
```
NAME                                           STATUS   ROLES    AGE   VERSION
ip-10-0-1-123.us-east-2.compute.internal      Ready    <none>   2m    v1.34.0-eks-xxxxxx
ip-10-0-2-234.us-east-2.compute.internal      Ready    <none>   2m    v1.34.0-eks-xxxxxx
ip-10-0-3-345.us-east-2.compute.internal      Ready    <none>   2m    v1.34.0-eks-xxxxxx
```

### Step 4: Verify kubectl Context

```bash
kubectl config current-context
```

Should show: `arn:aws:eks:us-east-2:ACCOUNT_ID:cluster/CLUSTER_NAME` or similar.

## Phase 2: Vault PKI

Deploy HashiCorp Vault as the certificate authority for all TLS certificates.

### Step 1: Review Configuration

Verify Vault settings in `config.env`:
- `VAULT_NAMESPACE="vault"`
- `VAULT_RELEASE_NAME="vault"`

### Step 2: Run Phase 2 Setup

```bash
cd ../phase2-certificates
chmod +x setup.sh
./setup.sh
```

This will:
- Create `vault` namespace
- Install Vault via Helm in standalone mode with persistent storage
- Initialize and unseal Vault (save the unseal keys and root token!)
- Configure PKI secrets engine at `pki` path
- Generate root CA certificate with 10-year TTL
- Configure certificate roles for:
  - CockroachDB node certificates
  - CockroachDB client certificates (root, pgb_app_user, pgb_batch_user, pgb_admin_user, flyway_svc)
  - PgBouncer server certificates (for app/batch/admin pools)
  - PgBouncer client certificates (for connecting to CockroachDB)
- Create Vault Issuer for cert-manager integration

### Step 3: Verify Vault

```bash
kubectl get pods -n vault
```

Expected output:
```
NAME                                    READY   STATUS    RESTARTS   AGE
vault-0                                 1/1     Running   0          2m
vault-agent-injector-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
```

### Step 4: Test Certificate Generation

```bash
# Port-forward to Vault
kubectl port-forward -n vault vault-0 8200:8200 &

# Export Vault address and token (use root token from setup output)
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='<root-token-from-setup-output>'

# Test certificate issuance for CockroachDB node
vault write pki/issue/cockroachdb-server \
    common_name="cockroachdb.cockroachdb.svc.cluster.local" \
    alt_names="localhost,*.cockroachdb,*.cockroachdb.cockroachdb,*.cockroachdb.cockroachdb.svc.cluster.local" \
    ip_sans="127.0.0.1" \
    ttl="8760h"
```

You should receive a certificate in the response with `serial_number`, `certificate`, `private_key`, etc.

## Phase 3: CockroachDB Operator

Install the CockroachDB Kubernetes Operator and cert-manager.

### Step 1: Run Phase 3 Setup

```bash
cd ../phase3-operator
chmod +x setup.sh
./setup.sh
```

This will:
- Create `cockroachdb` namespace
- Install cert-manager from Jetstack Helm chart
- Create Vault Issuer for cert-manager (connects to Vault PKI)
- Install CockroachDB Kubernetes Operator from Cockroach Helm chart
- Wait for all components to be ready

### Step 2: Verify Operator

```bash
kubectl get pods -n cockroachdb-operator-system
```

Expected output:
```
NAME                                                  READY   STATUS    RESTARTS   AGE
cockroach-operator-manager-xxxxxxxxxx-xxxxx          1/1     Running   0          1m
```

### Step 3: Verify cert-manager

```bash
kubectl get pods -n cert-manager
```

Expected output:
```
NAME                                      READY   STATUS    RESTARTS   AGE
cert-manager-xxxxxxxxxx-xxxxx             1/1     Running   0          2m
cert-manager-cainjector-xxxxxxxxxx-xxxxx  1/1     Running   0          2m
cert-manager-webhook-xxxxxxxxxx-xxxxx     1/1     Running   0          2m
```

### Step 4: Verify Vault Issuer

```bash
kubectl get issuer -n cockroachdb
```

Expected output:
```
NAME            READY   AGE
vault-issuer    True    2m
```

## Phase 4: CockroachDB Cluster

Deploy the CockroachDB cluster with JWT authentication, roles, service accounts, and example RLS configuration.

### Step 1: Ensure Okta Configuration in config.env

Verify that `config.env` contains Okta configuration from Phase 0:

```bash
grep OKTA config.env
```

Should show:
```
export OKTA_ISSUER="..."
export OKTA_JWKS_URL="..."
export OKTA_CLIENT_ID="..."
export OKTA_AUDIENCE="..."
```

### Step 2: Run Phase 4 Setup

```bash
cd ../phase4-cluster
chmod +x setup.sh
./setup.sh
```

This will:
- Generate CockroachDB cluster manifest (3 nodes, 8 CPU limit per node, 24Gi memory per node)
- Create CockroachDB StatefulSet via CockroachDB Operator
- Wait for cluster to be ready (~5-10 minutes)
- Initialize cluster
- Generate node certificate via cert-manager + Vault PKI
- Generate client certificates for:
  - `root` (admin access, for DBA operations)
  - `pgb_app_user` (app pool service account)
  - `pgb_batch_user` (batch pool service account)
  - `pgb_admin_user` (admin pool service account)
  - `flyway_svc` (schema migration service account)
- Configure JWT authentication:
  - Set `server.jwt_authentication.enabled = true`
  - Set `server.jwt_authentication.jwks` to Okta JWKS URL
  - Set `server.jwt_authentication.audience` to configured audience
  - Set `server.jwt_authentication.claim` to `groups` (Okta group memberships)
- Create database roles:
  - **Parent roles (NOLOGIN)**: readonly, app, pipeline, powerbi, compliance, developer, admin
  - **Okta-mapped roles (NOLOGIN)**: advisor-team-east, advisor-team-west, client-services, compliance-team, fiduciary-admin, batch-service, developers
- Create service account SQL users (NOLOGIN, certificate-only):
  - `pgb_app_user` → granted `app` role
  - `pgb_batch_user` → granted `admin` role with BYPASSRLS
  - `pgb_admin_user` → granted `admin` role with BYPASSRLS
  - `flyway_svc` → granted `admin` role with BYPASSRLS
- Create databases: `metadata`, `staging`, `production`
- Create example `role_party_access` table (production database)
- Create example RLS policy on `accounts` table (stub, full schema applied in Phase 7)

### Step 3: Verify Cluster

```bash
kubectl get pods -n cockroachdb
```

Expected output:
```
NAME                        READY   STATUS    RESTARTS   AGE
example-crdb-cluster-0      1/1     Running   0          5m
example-crdb-cluster-1      1/1     Running   0          4m
example-crdb-cluster-2      1/1     Running   0          3m
```

### Step 4: Verify Certificates

```bash
kubectl get certificates -n cockroachdb
```

Expected output:
```
NAME                          READY   AGE
cockroachdb-node              True    5m
cockroachdb-client-root       True    4m
cockroachdb-client-pgb-app    True    4m
cockroachdb-client-pgb-batch  True    4m
cockroachdb-client-pgb-admin  True    4m
cockroachdb-client-flyway     True    4m
```

### Step 5: Test Database Access

```bash
# Port-forward to CockroachDB SQL port
kubectl port-forward -n cockroachdb example-crdb-cluster-0 26257:26257 &

# Connect using root certificate
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW DATABASES;"
```

Expected output:
```
  database_name
-----------------
  defaultdb
  metadata
  postgres
  production
  staging
  system
(6 rows)
```

### Step 6: Verify JWT Authentication Configuration

```bash
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW CLUSTER SETTING server.jwt_authentication.enabled;"

kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW CLUSTER SETTING server.jwt_authentication.jwks;"
```

### Step 7: Verify Roles and Users

```bash
# Check all roles
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW ROLES;"

# Check service account users
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SELECT username, \"isRole\" FROM system.users WHERE username LIKE 'pgb_%' OR username LIKE 'flyway_%';"
```

### Step 8: Access DB Console

```bash
# Port-forward to DB Console
kubectl port-forward -n cockroachdb example-crdb-cluster-0 8080:8080 &

# Open browser to: https://localhost:8080
# Username: root
# Password: (leave blank, using client certificate auth)
# Click "Advanced" and "Proceed to localhost (unsafe)" if self-signed cert warning appears
```

## Phase 5: PgBouncer Connection Pools

Deploy three PgBouncer connection pools with separate service accounts: app (50%), batch (40%), admin (10%).

### Step 1: Review Pool Configuration

Verify pool settings in `config.env`:

```bash
# Pool allocation percentages
export PGBOUNCER_APP_POOL_PCT="50"
export PGBOUNCER_BATCH_POOL_PCT="40"
export PGBOUNCER_ADMIN_POOL_PCT="10"

# Pool ports
export PGBOUNCER_APP_PORT="5432"
export PGBOUNCER_BATCH_PORT="5433"
export PGBOUNCER_ADMIN_PORT="5434"

# Pool replicas
export PGBOUNCER_APP_REPLICAS="3"
export PGBOUNCER_BATCH_REPLICAS="2"
export PGBOUNCER_ADMIN_REPLICAS="1"

# Pool mode
export PGBOUNCER_POOL_MODE="transaction"

# Client connection limits
export PGBOUNCER_MAX_CLIENT_CONN="1000"
```

**Connection Pool Calculation**:
- Total available connections to CockroachDB: `4 × 8 CPU × 3 nodes = 96 connections`
- App pool: `96 × 50% = 48 connections` → 16 per replica (3 replicas)
- Batch pool: `96 × 40% ≈ 38 connections` → 19 per replica (2 replicas)
- Admin pool: `96 × 10% ≈ 10 connections` → 10 per replica (1 replica)

### Step 2: Run Phase 5 Setup

```bash
cd ../phase5-pgbouncer
chmod +x setup.sh
./setup.sh
```

This will:
- Create `pgbouncer` SQL user in CockroachDB (for admin console access)
- Generate certificates for each pool via cert-manager + Vault PKI:
  - **pgbouncer-app-server** (TLS for apps connecting to app pool)
  - **pgbouncer-app-client** (TLS for app pool connecting to CockroachDB as `pgb_app_user`)
  - **pgbouncer-batch-server** (TLS for batch jobs connecting to batch pool)
  - **pgbouncer-batch-client** (TLS for batch pool connecting to CockroachDB as `pgb_batch_user`)
  - **pgbouncer-admin-server** (TLS for admin tools connecting to admin pool)
  - **pgbouncer-admin-client** (TLS for admin pool connecting to CockroachDB as `pgb_admin_user`)
- Create ConfigMaps for each pool:
  - `pgbouncer-app-config` (pool_size=16, max_client_conn=1000, transaction pooling)
  - `pgbouncer-batch-config` (pool_size=19, max_client_conn=1000, transaction pooling)
  - `pgbouncer-admin-config` (pool_size=10, max_client_conn=200, transaction pooling)
- Deploy three PgBouncer Deployments:
  - `pgbouncer-app` (3 replicas, listens on port 5432)
  - `pgbouncer-batch` (2 replicas, listens on port 5433)
  - `pgbouncer-admin` (1 replica, listens on port 5434)
- Create three ClusterIP Services:
  - `pgbouncer-app.cockroachdb.svc.cluster.local:5432`
  - `pgbouncer-batch.cockroachdb.svc.cluster.local:5433`
  - `pgbouncer-admin.cockroachdb.svc.cluster.local:5434`
- Add Stakater Reloader annotations for auto-restart on ConfigMap changes

### Step 3: Verify PgBouncer Pods

```bash
kubectl get pods -n cockroachdb -l app.kubernetes.io/component=connection-pooler
```

Expected output:
```
NAME                               READY   STATUS    RESTARTS   AGE
pgbouncer-app-xxxxxxxxxx-xxxxx     1/1     Running   0          2m
pgbouncer-app-xxxxxxxxxx-xxxxx     1/1     Running   0          2m
pgbouncer-app-xxxxxxxxxx-xxxxx     1/1     Running   0          2m
pgbouncer-batch-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
pgbouncer-batch-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
pgbouncer-admin-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
```

### Step 4: Verify PgBouncer Services

```bash
kubectl get svc -n cockroachdb | grep pgbouncer
```

Expected output:
```
pgbouncer-app     ClusterIP   10.100.123.45   <none>   5432/TCP   2m
pgbouncer-batch   ClusterIP   10.100.123.46   <none>   5433/TCP   2m
pgbouncer-admin   ClusterIP   10.100.123.47   <none>   5434/TCP   2m
```

### Step 5: Test Connection Through Each Pool

```bash
# Test app pool
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql \
    --url "postgresql://root@pgbouncer-app:5432/defaultdb?sslmode=require" \
    --certs-dir=/cockroach/cockroach-certs \
    --execute="SELECT 'App pool connection successful' AS status;"

# Test batch pool
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql \
    --url "postgresql://root@pgbouncer-batch:5433/defaultdb?sslmode=require" \
    --certs-dir=/cockroach/cockroach-certs \
    --execute="SELECT 'Batch pool connection successful' AS status;"

# Test admin pool
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql \
    --url "postgresql://root@pgbouncer-admin:5434/defaultdb?sslmode=require" \
    --certs-dir=/cockroach/cockroach-certs \
    --execute="SELECT 'Admin pool connection successful' AS status;"
```

### Step 6: Check PgBouncer Pool Stats

```bash
# Check app pool statistics
kubectl exec -n cockroachdb deployment/pgbouncer-app -- \
    psql -p 5432 pgbouncer -U pgbouncer -c 'SHOW POOLS;'

# Check batch pool statistics
kubectl exec -n cockroachdb deployment/pgbouncer-batch -- \
    psql -p 5433 pgbouncer -U pgbouncer -c 'SHOW POOLS;'

# Check admin pool statistics
kubectl exec -n cockroachdb deployment/pgbouncer-admin -- \
    psql -p 5434 pgbouncer -U pgbouncer -c 'SHOW POOLS;'
```

## Phase 6: Istio Service Mesh

Deploy Istio service mesh for JWT validation, mTLS, and traffic management.

### Step 1: Install Istio Operator

```bash
cd ../phase6-istio
chmod +x setup.sh
./setup.sh
```

This will:
- Install Istio base CRDs
- Install Istio control plane (istiod) in `istio-system` namespace
- Install Istio ingress gateway with AWS Network Load Balancer
- Enable automatic sidecar injection on `cockroachdb` namespace
- Create RequestAuthentication resource for Okta JWT validation
- Create AuthorizationPolicy to require valid JWT for ingress traffic
- Create Gateway and VirtualService for routing PostgreSQL traffic

### Step 2: Verify Istio Installation

```bash
kubectl get pods -n istio-system
```

Expected output:
```
NAME                                    READY   STATUS    RESTARTS   AGE
istiod-xxxxxxxxxx-xxxxx                 1/1     Running   0          2m
istio-ingressgateway-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
```

### Step 3: Verify Sidecar Injection Enabled

```bash
kubectl get namespace cockroachdb -o jsonpath='{.metadata.labels.istio-injection}'
```

Expected output: `enabled`

### Step 4: Get Ingress Gateway External Endpoint

```bash
export INGRESS_HOST=$(kubectl get svc -n istio-system istio-ingressgateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $INGRESS_HOST
```

Note this ELB DNS name - this is the external entry point for client connections with JWT authentication.

### Step 5: Verify JWT Authentication Configuration

```bash
kubectl get requestauthentication -n cockroachdb
kubectl get authorizationpolicy -n cockroachdb
```

Expected output:
```
NAME                    AGE
jwt-auth-okta           2m

NAME                    AGE
require-jwt             2m
```

## Phase 7: Flyway Schema Migrations

Deploy Flyway for automated schema migrations using SQL scripts from the sample-data-pipeline repository.

### Step 1: Clone sample-data-pipeline Repository

```bash
cd /tmp
git clone https://github.com/roachlong/sample-data-pipeline.git
cd sample-data-pipeline
```

### Step 2: Copy Migration Scripts to Phase 7

```bash
cd /path/to/distributed-connection-pooling/kubernetes/eks/manifests/phase7-flyway

# Create sql directories
mkdir -p sql/metadata sql/staging sql/production

# Copy scripts from sample-data-pipeline
cp /tmp/sample-data-pipeline/flyway/sql/metadata/*.sql sql/metadata/ || echo "No metadata migrations yet"
cp /tmp/sample-data-pipeline/flyway/sql/staging/*.sql sql/staging/ || echo "No staging migrations yet"
cp /tmp/sample-data-pipeline/flyway/sql/production/*.sql sql/production/
```

### Step 3: Add Custom RLS Scripts

The setup script will create additional migration files for RLS:

- `sql/production/V002__add_role_party_access.sql` - Create `role_party_access` mapping table
- `sql/production/V015__enable_rls_accounts.sql` - Enable RLS on `accounts` table
- `sql/production/V016__enable_rls_parties.sql` - Enable RLS on `parties` table

These are applied AFTER the base schema from sample-data-pipeline.

### Step 4: Run Phase 7 Setup

```bash
chmod +x setup.sh
./setup.sh
```

This will:
- Generate RLS migration scripts (V002, V015, V016)
- Create ConfigMaps for Flyway SQL scripts (one per database)
- Create Flyway Kubernetes Job for each database:
  - `flyway-metadata-migration` (applies metadata schema)
  - `flyway-staging-migration` (applies staging schema)
  - `flyway-production-migration` (applies production schema + RLS)
- Flyway connects directly to CockroachDB:26257 (bypasses PgBouncer)
- Uses `flyway_svc` client certificate for authentication
- Executes migrations in version order (V001, V002, V003, ...)
- Wait for all migration jobs to complete

### Step 5: Verify Migration Jobs

```bash
kubectl get jobs -n cockroachdb | grep flyway
```

Expected output:
```
NAME                          COMPLETIONS   DURATION   AGE
flyway-metadata-migration     1/1           45s        3m
flyway-staging-migration      1/1           52s        3m
flyway-production-migration   1/1           67s        3m
```

### Step 6: Verify Migration History

```bash
# Check metadata database migrations
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=metadata \
    --execute="SELECT installed_rank, version, description, success FROM flyway_schema_history ORDER BY installed_rank;"

# Check staging database migrations
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=staging \
    --execute="SELECT installed_rank, version, description, success FROM flyway_schema_history ORDER BY installed_rank;"

# Check production database migrations
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production \
    --execute="SELECT installed_rank, version, description, success FROM flyway_schema_history ORDER BY installed_rank;"
```

### Step 7: Verify RLS is Enabled

```bash
# Verify RLS on accounts table
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production \
    --execute="SELECT tablename, rowsecurity FROM pg_tables WHERE tablename IN ('accounts', 'parties');"

# Verify RLS policies exist
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production \
    --execute="SELECT tablename, policyname, cmd, qual FROM pg_policies WHERE tablename IN ('accounts', 'parties');"
```

Expected: `rowsecurity = t` (true) for both tables, and policies named `role_based_account_access` and `role_based_party_access`.

## Phase 9: Enterprise Features

Enable CockroachDB Enterprise features: licensing, backup/restore, encryption-at-rest, and changefeeds.

### Prerequisites

- CockroachDB Enterprise license (request trial at https://www.cockroachlabs.com/get-started-cockroachdb/)
- S3 bucket for backups (will be created in this phase)

### Step 1: Set Enterprise License

```bash
cd ../phase9-enterprise
chmod +x setup.sh

# Add your enterprise license to config.env
vi ../../config.env
export CRDB_ENTERPRISE_LICENSE="your-license-key-here"
```

### Step 2: Run Phase 9 Setup

```bash
./setup.sh
```

This will:
- Create S3 bucket for backups with versioning enabled
- Create IAM role for CockroachDB service account (IRSA)
- Set CockroachDB Enterprise license via SQL
- Enable cluster settings for enterprise features
- Configure automatic full and incremental backups to S3
- Enable encryption-at-rest with customer-managed key (if configured)
- Create changefeed example for audit events

### Step 3: Verify Enterprise License

```bash
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW CLUSTER SETTING cluster.organization;"

kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW CLUSTER SETTING enterprise.license;"
```

### Step 4: Verify Backup Configuration

```bash
# Check backup schedule
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW SCHEDULES;"

# List backups in S3
aws s3 ls s3://${BACKUP_BUCKET_NAME}/cockroachdb/backups/ --recursive
```

### Step 5: Test Backup and Restore

```bash
# Manually trigger a backup
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="BACKUP DATABASE production INTO 's3://${BACKUP_BUCKET_NAME}/cockroachdb/backups/manual?AWS_ACCESS_KEY_ID={ACCESS_KEY}&AWS_SECRET_ACCESS_KEY={SECRET_KEY}';"

# List backups
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW BACKUPS IN 's3://${BACKUP_BUCKET_NAME}/cockroachdb/backups/manual?AWS_ACCESS_KEY_ID={ACCESS_KEY}&AWS_SECRET_ACCESS_KEY={SECRET_KEY}';"
```

## Phase 10: Observability Stack

Deploy Prometheus, Grafana, and Alertmanager for monitoring, metrics, and alerting.

### Step 1: Run Phase 10 Setup

```bash
cd ../phase10-observability
chmod +x setup.sh
./setup.sh
```

This will:
- Create `monitoring` namespace
- Install Prometheus Operator via kube-prometheus-stack Helm chart
- Install Grafana with pre-configured CockroachDB dashboards
- Install Alertmanager with alert rules for CockroachDB
- Install PgBouncer exporter for connection pool metrics
- Create ServiceMonitor resources for:
  - CockroachDB pods (port 8080, `_status/vars` endpoint)
  - PgBouncer pods (port 9127, Prometheus exporter)
- Configure Prometheus scrape configs
- Import CockroachDB Grafana dashboards from cockroach-community
- Create alert rules:
  - Node down
  - High query latency (p99 > 1s)
  - Replication lag (> 10s)
  - Under-replicated ranges
  - Low disk space (< 20%)
  - High CPU usage (> 80%)
  - Connection pool exhaustion (< 10% available)

### Step 2: Verify Observability Components

```bash
kubectl get pods -n monitoring
```

Expected output:
```
NAME                                                     READY   STATUS    RESTARTS   AGE
prometheus-operator-xxxxxxxxxx-xxxxx                     1/1     Running   0          2m
prometheus-prometheus-kube-prometheus-prometheus-0       2/2     Running   0          2m
alertmanager-prometheus-kube-prometheus-alertmanager-0   2/2     Running   0          2m
prometheus-kube-prometheus-grafana-xxxxxxxxxx-xxxxx      3/3     Running   0          2m
```

### Step 3: Access Grafana

```bash
# Port-forward to Grafana
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-grafana 3000:80 &

# Get Grafana admin password
kubectl get secret -n monitoring prometheus-kube-prometheus-grafana \
    -o jsonpath="{.data.admin-password}" | base64 --decode
echo

# Open browser to: http://localhost:3000
# Username: admin
# Password: <from above command>
```

### Step 4: View CockroachDB Dashboards

In Grafana:
1. Navigate to **Dashboards** → **Browse**
2. Find the **CockroachDB** folder
3. Open dashboards:
   - CockroachDB Overview
   - CockroachDB Runtime
   - CockroachDB SQL Performance
   - CockroachDB Replication
   - PgBouncer Connection Pools

### Step 5: Verify Prometheus Targets

```bash
# Port-forward to Prometheus
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 &

# Open browser to: http://localhost:9090
# Navigate to Status → Targets
# Verify CockroachDB and PgBouncer targets are UP
```

### Step 6: Test Alerting

```bash
# View active alerts
kubectl port-forward -n monitoring svc/alertmanager-operated 9093:9093 &

# Open browser to: http://localhost:9093
# You should see any active alerts (initially none if cluster is healthy)
```

## Phase 11: Security Hardening

Apply security best practices: network policies, pod security standards, IRSA, and secrets management.

### Step 1: Run Phase 11 Setup

```bash
cd ../phase11-security
chmod +x setup.sh
./setup.sh
```

This will:
- Create Kubernetes NetworkPolicies:
  - Deny all ingress/egress by default
  - Allow CockroachDB inter-node communication (ports 26257, 8080)
  - Allow PgBouncer → CockroachDB (port 26257)
  - Allow applications → PgBouncer (ports 5432, 5433, 5434)
  - Allow Prometheus → CockroachDB metrics (port 8080)
  - Allow Prometheus → PgBouncer exporter (port 9127)
  - Allow DNS resolution (kube-dns)
  - Deny pod-to-internet egress (only allow to AWS services via VPC endpoints)
- Apply Pod Security Standards:
  - Enforce `restricted` pod security standard on `cockroachdb` namespace
  - CockroachDB pods run as non-root user (UID 1000)
  - PgBouncer pods run as non-root user (UID 999)
  - Drop all capabilities except NET_BIND_SERVICE
  - Set readOnlyRootFilesystem where possible
- Configure IAM Roles for Service Accounts (IRSA):
  - CockroachDB service account → S3 backup bucket access
  - Fluent Bit service account → S3 audit log bucket access
  - External DNS service account → Route53 access (if using custom domain)
- Rotate certificates:
  - Reduce certificate TTL to 90 days
  - Enable automatic rotation via cert-manager
- Enable Secrets encryption at rest:
  - Configure AWS KMS key for EKS secrets encryption
  - Re-encrypt existing secrets

### Step 2: Verify Network Policies

```bash
kubectl get networkpolicies -n cockroachdb
```

Expected output:
```
NAME                          POD-SELECTOR                      AGE
deny-all-ingress-egress       <none>                            2m
allow-crdb-inter-node         app=cockroachdb                   2m
allow-crdb-from-pgbouncer     app=cockroachdb                   2m
allow-pgbouncer-from-apps     app.kubernetes.io/component=...   2m
allow-prometheus-scrape       <all pods>                        2m
allow-dns-egress              <all pods>                        2m
```

### Step 3: Verify Pod Security

```bash
# Check pod security standard on namespace
kubectl get namespace cockroachdb -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}'

# Verify pods are running as non-root
kubectl get pods -n cockroachdb -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.securityContext.runAsNonRoot}{"\n"}{end}'
```

### Step 4: Verify IRSA Configuration

```bash
# Check service account annotations
kubectl get sa -n cockroachdb cockroachdb -o yaml | grep eks.amazonaws.com/role-arn

# Verify pods have AWS credentials via IRSA
kubectl exec -n cockroachdb example-crdb-cluster-0 -- env | grep AWS
```

### Step 5: Test Network Policy Enforcement

```bash
# This should FAIL (pod-to-internet blocked):
kubectl run -n cockroachdb curl-test --image=curlimages/curl:latest --rm -it -- \
    curl -v https://google.com

# This should SUCCEED (pod-to-pod within namespace allowed):
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    nc -zv example-crdb-cluster-1.example-crdb-cluster.cockroachdb 26257
```

## Phase 12: Audit Logging

Deploy Fluent Bit to collect CockroachDB audit logs and ship them to S3 with Object Lock (WORM).

### Prerequisites

- S3 bucket for audit logs with Object Lock enabled (created in this phase)
- IRSA configured for Fluent Bit service account (created in this phase)

### Step 1: Run Phase 12 Setup

```bash
cd ../phase12-audit
chmod +x setup.sh
./setup.sh
```

This will:
- Create S3 bucket for audit logs:
  - Enable versioning
  - Enable Object Lock in compliance mode
  - Set default retention period (7 years for compliance)
  - Enable bucket encryption (AES-256 or KMS)
- Create IAM role for Fluent Bit service account (IRSA)
- Enable CockroachDB audit logging:
  - Set `sql.log.all_statements.enabled = true` (log all SQL statements)
  - Set `sql.log.slow_query.latency_threshold = '100ms'` (log slow queries)
  - Set `server.auth_log.sql_connections.enabled = true` (log auth events)
  - Set `server.auth_log.sql_sessions.enabled = true` (log session events)
- Deploy Fluent Bit DaemonSet:
  - Collect logs from CockroachDB pods (stdout, stderr, and log files)
  - Parse JSON-formatted logs
  - Enrich with Kubernetes metadata (pod name, namespace, labels)
  - Ship to S3 bucket with partition keys: `year=YYYY/month=MM/day=DD/hour=HH/`
  - Buffer logs locally in case of S3 unavailability
- Create Athena table for querying audit logs (optional)

### Step 2: Verify Fluent Bit Deployment

```bash
kubectl get pods -n logging
```

Expected output:
```
NAME                    READY   STATUS    RESTARTS   AGE
fluent-bit-xxxxx        1/1     Running   0          2m
fluent-bit-xxxxx        1/1     Running   0          2m
fluent-bit-xxxxx        1/1     Running   0          2m
```

### Step 3: Verify Audit Logging is Enabled

```bash
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW CLUSTER SETTING sql.log.all_statements.enabled;"

kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW CLUSTER SETTING server.auth_log.sql_connections.enabled;"
```

Expected: `true` for both settings.

### Step 4: Verify Logs are Shipped to S3

```bash
# List objects in S3 audit bucket (wait 5-10 minutes for initial buffering)
aws s3 ls s3://${AUDIT_BUCKET_NAME}/cockroachdb/audit-logs/ --recursive | head -20

# Download and view a log file
aws s3 cp s3://${AUDIT_BUCKET_NAME}/cockroachdb/audit-logs/year=2026/month=06/day=09/hour=12/logs.json.gz - | gunzip | jq .
```

### Step 5: Query Audit Logs with Athena (Optional)

```bash
# Create Athena database and table
aws athena start-query-execution \
    --query-string "CREATE EXTERNAL TABLE IF NOT EXISTS cockroachdb_audit_logs (...)" \
    --result-configuration "OutputLocation=s3://${ATHENA_RESULTS_BUCKET}/" \
    --region us-east-2

# Query example: Find all failed authentication attempts
aws athena start-query-execution \
    --query-string "SELECT * FROM cockroachdb_audit_logs WHERE event_type = 'client_authentication_failed' AND year = '2026' AND month = '06' LIMIT 100;" \
    --result-configuration "OutputLocation=s3://${ATHENA_RESULTS_BUCKET}/" \
    --region us-east-2
```

### Step 6: Verify Object Lock Retention

```bash
# Check Object Lock configuration
aws s3api get-object-lock-configuration --bucket ${AUDIT_BUCKET_NAME}

# Verify objects have retention period
aws s3api head-object \
    --bucket ${AUDIT_BUCKET_NAME} \
    --key cockroachdb/audit-logs/year=2026/month=06/day=09/hour=12/logs.json.gz \
    | jq '.ObjectLockRetainUntilDate'
```

Expected: Retention date 7 years in the future (for compliance).

## Phase 13: Physical Cluster Replication (PCR)

Deploy a second CockroachDB cluster in us-west-2 for disaster recovery using Physical Cluster Replication.

### Prerequisites

- CockroachDB Enterprise license (Phase 9 must be completed)
- Second EKS cluster in us-west-2 (or create new one in this phase)

### Architecture

```
┌─────────────────────────────────────┐      ┌─────────────────────────────────────┐
│  Primary Cluster (us-east-2)        │      │  Standby Cluster (us-west-2)        │
│  ─────────────────────────────────  │      │  ─────────────────────────────────  │
│                                     │      │                                     │
│  ┌────────────────────────────────┐ │      │  ┌────────────────────────────────┐ │
│  │  CockroachDB East (3 nodes)    │ │      │  │  CockroachDB West (3 nodes)    │ │
│  │  - Active read/write           │ │──────▶  │  - Standby (read-only)         │ │
│  │  - App/Batch pools             │ │ PCR  │  │  - Analytics pool (100%)       │ │
│  │  - RLS enforced                │ │      │  │  - Historical queries          │ │
│  └────────────────────────────────┘ │      │  └────────────────────────────────┘ │
│                                     │      │                                     │
│  ┌────────────────────────────────┐ │      │  ┌────────────────────────────────┐ │
│  │  PgBouncer                     │ │      │  │  PgBouncer Analytics           │ │
│  │  - App pool (50%)              │ │      │  │  - Analytics pool (100%)       │ │
│  │  - Batch pool (40%)            │ │      │  │  - Power BI connector          │ │
│  │  - Admin pool (10%)            │ │      │  └────────────────────────────────┘ │
│  └────────────────────────────────┘ │      │                                     │
└─────────────────────────────────────┘      └─────────────────────────────────────┘
```

### Step 1: Create West EKS Cluster (if needed)

```bash
cd ../phase13-pcr

# Update config.env with West region settings
export AWS_REGION_WEST="us-west-2"
export EKS_CLUSTER_NAME_WEST="example-crdb-eks-west"

# Create West cluster using Phase 1 scripts
./setup-west-cluster.sh
```

This creates a separate EKS cluster in us-west-2 with the same configuration as East.

### Step 2: Run Phase 13 Setup

```bash
chmod +x setup.sh
./setup.sh
```

This will:
- Deploy Vault PKI in West cluster
- Deploy CockroachDB Operator in West cluster
- Deploy CockroachDB Standby cluster (3 nodes) in West
- Configure Physical Cluster Replication:
  - Create replication stream from East (primary) to West (standby)
  - Set replication mode to FULL (replicate all databases)
  - Configure retention window (24 hours for point-in-time recovery)
- Deploy PgBouncer Analytics pool in West:
  - Single pool, 100% of West cluster connections (96 connections)
  - 3 replicas for HA
  - Port 5432
  - Read-only queries against replicated data
- Configure DNS routing:
  - `crdb-east.example.com` → East cluster (read-write)
  - `crdb-west.example.com` → West cluster (read-only analytics)
- Set up automated failover scripts (manual invocation for safety)

### Step 3: Verify PCR Replication

```bash
# Check replication status on primary (East)
kubectl exec -n cockroachdb example-crdb-cluster-0 --context east-cluster -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SELECT * FROM crdb_internal.cluster_replication_streams;"

# Check replication lag
kubectl exec -n cockroachdb example-crdb-cluster-0 --context east-cluster -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SELECT stream_id, lag FROM crdb_internal.cluster_replication_streams;"
```

Expected: `lag` should be < 10 seconds under normal conditions.

### Step 4: Verify West Standby Cluster

```bash
# Check West cluster status
kubectl exec -n cockroachdb example-crdb-cluster-west-0 --context west-cluster -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW DATABASES;"

# Verify read-only mode
kubectl exec -n cockroachdb example-crdb-cluster-west-0 --context west-cluster -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production \
    --execute="SELECT COUNT(*) FROM accounts;"

# This should FAIL (standby is read-only):
kubectl exec -n cockroachdb example-crdb-cluster-west-0 --context west-cluster -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production \
    --execute="INSERT INTO accounts (...) VALUES (...);"
```

### Step 5: Verify Analytics Pool

```bash
# Port-forward to West analytics pool
kubectl port-forward -n cockroachdb --context west-cluster svc/pgbouncer-analytics 5435:5432 &

# Connect with psql
psql "postgresql://root@localhost:5435/production?sslmode=require" \
    --set=sslcert=/path/to/client.root.crt \
    --set=sslkey=/path/to/client.root.key \
    -c "SELECT party_id, COUNT(*) FROM accounts GROUP BY party_id;"
```

### Step 6: Deploy Power BI Connector (Optional)

```bash
# Install Power BI Gateway on Windows VM in VPC
# Configure connection to pgbouncer-analytics.cockroachdb.svc.cluster.local:5432

# Test connection from Power BI Desktop
# Connection string: pgbouncer-analytics.cockroachdb.svc.cluster.local
# Port: 5432
# Database: production
# Authentication: Client certificate (pgb_analytics_user)
```

### Step 7: Test Failover (DR Exercise)

**WARNING**: This promotes West to primary and demotes East to standby. Only do this during a planned DR exercise.

```bash
# Trigger manual failover
./failover-to-west.sh

# Verify West is now primary (read-write)
kubectl exec -n cockroachdb example-crdb-cluster-west-0 --context west-cluster -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production \
    --execute="INSERT INTO accounts (party_id, account_number, ...) VALUES (...);"

# Verify East is now standby (read-only)
kubectl exec -n cockroachdb example-crdb-cluster-0 --context east-cluster -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production \
    --execute="SELECT * FROM accounts WHERE account_id = '...';"
```

### Step 8: Failback to East

```bash
# After DR exercise, fail back to East as primary
./failback-to-east.sh

# Verify East is primary again
kubectl exec -n cockroachdb example-crdb-cluster-0 --context east-cluster -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SELECT * FROM crdb_internal.cluster_replication_streams;"
```

## Phase 14: GitOps (Optional)

Deploy ArgoCD for GitOps-based application delivery and continuous deployment.

### Step 1: Install ArgoCD

```bash
cd ../phase14-gitops
chmod +x setup.sh
./setup.sh
```

This will:
- Create `argocd` namespace
- Install ArgoCD via Helm chart
- Configure ArgoCD to manage itself (app-of-apps pattern)
- Create ArgoCD Applications for each phase:
  - `vault-pki`
  - `cockroachdb-operator`
  - `cockroachdb-cluster`
  - `pgbouncer-pools`
  - `istio`
  - `flyway-migrations`
  - `observability-stack`
  - `security-policies`
  - `audit-logging`
- Configure automated sync with Git repository
- Enable auto-sync and self-healing for production namespaces
- Set up RBAC for ArgoCD users

### Step 2: Access ArgoCD UI

```bash
# Get ArgoCD admin password
kubectl get secret -n argocd argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 --decode
echo

# Port-forward to ArgoCD server
kubectl port-forward -n argocd svc/argocd-server 8080:443 &

# Open browser to: https://localhost:8080
# Username: admin
# Password: <from above command>
```

### Step 3: Connect Git Repository

In ArgoCD UI:
1. Navigate to **Settings** → **Repositories**
2. Click **Connect Repo**
3. Enter repository URL: `https://github.com/your-org/distributed-connection-pooling`
4. Choose authentication method (SSH key or HTTPS token)
5. Click **Connect**

### Step 4: Sync Applications

```bash
# Sync all applications
argocd app sync --grpc-web --server localhost:8080 --insecure \
    vault-pki cockroachdb-operator cockroachdb-cluster pgbouncer-pools \
    istio flyway-migrations observability-stack security-policies audit-logging

# Watch sync status
argocd app list --grpc-web --server localhost:8080 --insecure
```

### Step 5: Enable Auto-Sync

```bash
# Enable auto-sync for all applications
for app in vault-pki cockroachdb-operator cockroachdb-cluster pgbouncer-pools istio flyway-migrations observability-stack security-policies audit-logging; do
    argocd app set $app --sync-policy automated --auto-prune --self-heal \
        --grpc-web --server localhost:8080 --insecure
done
```

### Step 6: Test GitOps Workflow

```bash
# Make a change to pgbouncer-app replicas in Git
cd /path/to/distributed-connection-pooling
vi kubernetes/eks/manifests/phase5-pgbouncer/pgbouncer-app-deployment.yaml
# Change replicas from 3 to 4

git add .
git commit -m "Scale pgbouncer-app to 4 replicas"
git push origin main

# ArgoCD will automatically detect the change and sync within 3 minutes
# Watch sync status
argocd app watch pgbouncer-pools --grpc-web --server localhost:8080 --insecure

# Verify new replica is running
kubectl get pods -n cockroachdb -l app=pgbouncer-app
```

## Post-Deployment Validation

### End-to-End Connection Test

Test the complete flow: External client → Istio → PgBouncer → CockroachDB with JWT authentication and RLS filtering.

#### Step 1: Obtain JWT Token from Okta

```bash
# Use Okta's token endpoint to get a JWT token for a test user
curl -X POST https://your-okta-domain/oauth2/default/v1/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=your-client-id" \
  -d "client_secret=your-client-secret" \
  -d "username=advisor-east@example.com" \
  -d "password=test-password" \
  -d "scope=openid profile groups"

# Extract the id_token from the response
export JWT_TOKEN="eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9..."

# Decode and verify token claims
echo $JWT_TOKEN | cut -d. -f2 | base64 -d | jq .
# Verify 'groups' claim includes: ["example-crdb-advisor-team-east"]
```

#### Step 2: Test Connection via Istio Ingress

```bash
# Get Istio ingress gateway external hostname
export INGRESS_HOST=$(kubectl get svc -n istio-system istio-ingressgateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Connect via psql with JWT token
psql "postgresql://advisor-east@example.com@${INGRESS_HOST}:5432/production?sslmode=require" \
    --set=jwt_token="${JWT_TOKEN}" \
    -c "SELECT current_user, current_database();"
```

#### Step 3: Test RLS Filtering

```bash
# Query accounts through app pool with JWT token
# User is in advisor-team-east group, should only see East party accounts

psql "postgresql://advisor-east@example.com@${INGRESS_HOST}:5432/production?sslmode=require" \
    --set=jwt_token="${JWT_TOKEN}" <<EOF
SELECT party_id, account_number, account_type, balance
FROM accounts
LIMIT 10;
EOF

# Expected: Only accounts for parties where advisor-team-east has access in role_party_access table
```

### RLS Validation

Test that Row-Level Security correctly filters data based on user roles from JWT token.

#### Step 1: Populate Test Data

```bash
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production <<EOF
-- Insert test parties
INSERT INTO parties (party_id, party_name, party_type, region) VALUES
('11111111-1111-1111-1111-111111111111', 'Party East 1', 'individual', 'us-east'),
('22222222-2222-2222-2222-222222222222', 'Party West 1', 'individual', 'us-west'),
('33333333-3333-3333-3333-333333333333', 'Party East 2', 'corporate', 'us-east');

-- Insert test accounts
INSERT INTO accounts (party_id, account_number, account_type, account_status, balance, currency_code, source_system, source_record_id) VALUES
('11111111-1111-1111-1111-111111111111', 'ACCT-EAST-001', 'checking', 'active', 10000.00, 'USD', 'core_banking', 'CB-001'),
('22222222-2222-2222-2222-222222222222', 'ACCT-WEST-001', 'checking', 'active', 20000.00, 'USD', 'core_banking', 'CB-002'),
('33333333-3333-3333-3333-333333333333', 'ACCT-EAST-002', 'savings', 'active', 50000.00, 'USD', 'core_banking', 'CB-003');

-- Populate role_party_access table
INSERT INTO role_party_access (role_name, party_id, access_level) VALUES
('advisor-team-east', '11111111-1111-1111-1111-111111111111', 'read_write'),
('advisor-team-east', '33333333-3333-3333-3333-333333333333', 'read_write'),
('advisor-team-west', '22222222-2222-2222-2222-222222222222', 'read_write'),
('client-services', '11111111-1111-1111-1111-111111111111', 'read_only'),
('client-services', '22222222-2222-2222-2222-222222222222', 'read_only'),
('client-services', '33333333-3333-3333-3333-333333333333', 'read_only');
EOF
```

#### Step 2: Test RLS with Different Roles

```bash
# Test as advisor-team-east (should see ACCT-EAST-001 and ACCT-EAST-002)
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production <<EOF
BEGIN;
SET LOCAL app.current_user = 'advisor-east@example.com';
SET LOCAL app.current_roles = 'advisor-team-east';
SELECT account_number, party_id, balance FROM accounts ORDER BY account_number;
COMMIT;
EOF

# Expected output:
#   account_number |               party_id               | balance
# -----------------+--------------------------------------+----------
#   ACCT-EAST-001  | 11111111-1111-1111-1111-111111111111 | 10000.00
#   ACCT-EAST-002  | 33333333-3333-3333-3333-333333333333 | 50000.00

# Test as advisor-team-west (should only see ACCT-WEST-001)
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production <<EOF
BEGIN;
SET LOCAL app.current_user = 'advisor-west@example.com';
SET LOCAL app.current_roles = 'advisor-team-west';
SELECT account_number, party_id, balance FROM accounts ORDER BY account_number;
COMMIT;
EOF

# Expected output:
#   account_number |               party_id               | balance
# -----------------+--------------------------------------+----------
#   ACCT-WEST-001  | 22222222-2222-2222-2222-222222222222 | 20000.00

# Test as client-services (should see all three accounts, read-only)
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production <<EOF
BEGIN;
SET LOCAL app.current_user = 'client-services@example.com';
SET LOCAL app.current_roles = 'client-services';
SELECT account_number, party_id, balance FROM accounts ORDER BY account_number;
COMMIT;
EOF

# Expected output: All three accounts

# Test write with read-only role (should FAIL)
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production <<EOF
BEGIN;
SET LOCAL app.current_user = 'client-services@example.com';
SET LOCAL app.current_roles = 'client-services';
UPDATE accounts SET balance = balance + 100 WHERE account_number = 'ACCT-EAST-001';
COMMIT;
EOF

# Expected: Error - new row violates row-level security policy (WITH CHECK failed)
```

### Connection Pool Monitoring

Monitor PgBouncer connection pool usage and performance.

```bash
# Check app pool statistics
kubectl exec -n cockroachdb deployment/pgbouncer-app -- \
    psql -p 5432 pgbouncer -U pgbouncer -c 'SHOW STATS;'

# Check server connections (to CockroachDB)
kubectl exec -n cockroachdb deployment/pgbouncer-app -- \
    psql -p 5432 pgbouncer -U pgbouncer -c 'SHOW SERVERS;'

# Check client connections (from applications)
kubectl exec -n cockroachdb deployment/pgbouncer-app -- \
    psql -p 5432 pgbouncer -U pgbouncer -c 'SHOW CLIENTS;'

# Check pool health (should have ~16 active server connections per replica)
kubectl exec -n cockroachdb deployment/pgbouncer-app -- \
    psql -p 5432 pgbouncer -U pgbouncer -c 'SHOW POOLS;'

# Repeat for batch and admin pools (ports 5433, 5434)
```

### CockroachDB Health Check

```bash
# Check cluster health and node status
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach node status --certs-dir=/cockroach/cockroach-certs

# Check database sizes
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SELECT * FROM [SHOW DATABASES] ORDER BY database_name;"

# Check active queries
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SELECT query_id, node_id, user_name, application_name, start, query FROM [SHOW QUERIES] WHERE query NOT LIKE '%SHOW QUERIES%' ORDER BY start DESC LIMIT 20;"

# Check replication status
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SELECT range_id, start_pretty, end_pretty, replicas, learner_replicas FROM crdb_internal.ranges WHERE database_name = 'production' AND table_name = 'accounts' LIMIT 10;"
```

## Troubleshooting

### EKS Cluster Issues

**Problem**: `eksctl create cluster` fails with VPC limit error

**Solution**: Delete unused VPCs in the AWS console or request a limit increase via AWS Service Quotas.

**Problem**: Nodes not joining cluster

**Solution**: 
```bash
# Check node group status
aws eks describe-nodegroup --cluster-name example-crdb-eks --nodegroup-name example-crdb-ng-1

# Check node IAM role
aws iam get-role --role-name eksctl-example-crdb-eks-NodeInstanceRole-xxxxx

# Check node security group allows traffic from control plane
aws ec2 describe-security-groups --group-ids sg-xxxxx
```

### Vault Issues

**Problem**: Vault pods in CrashLoopBackOff

**Solution**:
```bash
# Check Vault logs
kubectl logs -n vault vault-0

# Common causes:
# 1. PVC not bound - check: kubectl get pvc -n vault
# 2. Storage class missing - check: kubectl get storageclass
# 3. Incorrect configuration - check: kubectl get configmap -n vault vault-config

# Delete and recreate
kubectl delete namespace vault
cd manifests/phase2-certificates
./teardown.sh
./setup.sh
```

**Problem**: Certificate generation fails with "permission denied" error

**Solution**:
```bash
# Check Vault token is valid
vault token lookup

# Re-authenticate
vault login <root-token>

# Check PKI secrets engine is enabled
vault secrets list | grep pki

# Re-enable if needed
vault secrets enable -path=pki pki
vault secrets tune -max-lease-ttl=87600h pki
```

### CockroachDB Issues

**Problem**: Pods stuck in Pending state

**Solution**:
```bash
# Check PVC status
kubectl get pvc -n cockroachdb

# Check storage class exists
kubectl get storageclass

# Describe pod to see events
kubectl describe pod -n cockroachdb example-crdb-cluster-0

# Common causes:
# 1. Insufficient disk space in node
# 2. PVC size too large for storage class
# 3. Node affinity rules preventing scheduling
```

**Problem**: Cluster not initializing

**Solution**:
```bash
# Check CockroachDB operator logs
kubectl logs -n cockroachdb-operator-system deployment/cockroach-operator-manager

# Check CRD status
kubectl get crdbcluster -n cockroachdb example-crdb-cluster -o yaml

# Manually initialize if needed
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach init --certs-dir=/cockroach/cockroach-certs --host=example-crdb-cluster-0.example-crdb-cluster.cockroachdb
```

**Problem**: JWT authentication not working

**Solution**:
```bash
# Verify JWT cluster settings
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW CLUSTER SETTING server.jwt_authentication.enabled;"

kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW CLUSTER SETTING server.jwt_authentication.jwks;"

# Test JWKS endpoint accessibility from within cluster
kubectl run -n cockroachdb curl-test --image=curlimages/curl:latest --rm -it -- \
    curl -v https://your-okta-domain/oauth2/default/v1/keys

# Decode JWT token to verify claims
echo $JWT_TOKEN | cut -d. -f2 | base64 -d | jq .
# Ensure 'aud' matches OKTA_AUDIENCE
# Ensure 'iss' matches OKTA_ISSUER
# Ensure 'groups' claim exists and contains expected groups
```

### PgBouncer Issues

**Problem**: PgBouncer pods failing to start

**Solution**:
```bash
# Check logs for specific errors
kubectl logs -n cockroachdb deployment/pgbouncer-app

# Common issues:
# 1. Certificate permissions - ensure tls.key has mode 0600
kubectl exec -n cockroachdb deployment/pgbouncer-app -- ls -l /pgbouncer-certs/tls.key

# 2. ConfigMap syntax error - validate pgbouncer.ini
kubectl get configmap -n cockroachdb pgbouncer-app-config -o yaml

# 3. Backend unreachable - test connectivity to CockroachDB
kubectl exec -n cockroachdb deployment/pgbouncer-app -- \
    nc -zv example-crdb-cluster-public 26257
```

**Problem**: Connection refused when connecting through PgBouncer

**Solution**:
```bash
# Verify PgBouncer is listening on correct port
kubectl exec -n cockroachdb deployment/pgbouncer-app -- netstat -tlnp | grep 5432

# Check PgBouncer logs for authentication errors
kubectl logs -n cockroachdb deployment/pgbouncer-app | grep -i "authentication\|error\|failed"

# Verify backend connection to CockroachDB works
kubectl exec -n cockroachdb deployment/pgbouncer-app -- \
    psql -h example-crdb-cluster-public -p 26257 -U pgb_app_user -d defaultdb

# Check client certificate is valid
kubectl get secret -n cockroachdb pgbouncer-app-client -o yaml
```

**Problem**: Pool size mismatch warning during setup

**Solution**:
```bash
# Recalculate pool sizes based on formula:
# Total connections = 4 × CPU_LIMIT × NODE_COUNT
# Pool size per replica = (Total × POOL_PCT) / REPLICAS

# Example for app pool:
# Total = 4 × 8 × 3 = 96
# App pool = 96 × 0.50 = 48
# Per replica = 48 / 3 = 16

# Update config.env with correct values
vi config.env
export PGBOUNCER_APP_DEFAULT_POOL_SIZE="16"
export PGBOUNCER_BATCH_DEFAULT_POOL_SIZE="19"
export PGBOUNCER_ADMIN_DEFAULT_POOL_SIZE="10"

# Re-run Phase 5 setup
cd manifests/phase5-pgbouncer
./teardown.sh
./setup.sh
```

### Istio Issues

**Problem**: Istio installation fails

**Solution**:
```bash
# Check Istio operator logs (if using operator)
kubectl logs -n istio-operator deployment/istio-operator

# Check for conflicting installations
kubectl get crds | grep istio

# Uninstall and reinstall
istioctl uninstall --purge -y
kubectl delete namespace istio-system
cd manifests/phase6-istio
./setup.sh
```

**Problem**: JWT validation failing at ingress

**Solution**:
```bash
# Check RequestAuthentication configuration
kubectl get requestauthentication -n cockroachdb jwt-auth-okta -o yaml

# Verify JWKS URL is correct and accessible from cluster
kubectl run -n istio-system curl-test --image=curlimages/curl:latest --rm -it -- \
    curl -v https://your-okta-domain/oauth2/default/v1/keys

# Check Istio proxy logs on PgBouncer pod
kubectl logs -n cockroachdb <pgbouncer-app-pod-name> -c istio-proxy

# Test JWT token manually
curl -H "Authorization: Bearer ${JWT_TOKEN}" \
    https://${INGRESS_HOST}:5432
```

**Problem**: Ingress gateway not getting external IP (stuck in Pending)

**Solution**:
```bash
# Check service annotations
kubectl describe svc -n istio-system istio-ingressgateway

# Check AWS Load Balancer Controller logs (if using ALB)
kubectl logs -n kube-system deployment/aws-load-balancer-controller

# Verify subnet tags for auto-discovery
aws ec2 describe-subnets --filters "Name=tag:kubernetes.io/role/elb,Values=1"

# Manually create NLB if needed
kubectl annotate svc -n istio-system istio-ingressgateway \
    service.beta.kubernetes.io/aws-load-balancer-type=nlb
```

### Flyway Issues

**Problem**: Flyway migration job fails

**Solution**:
```bash
# Check job logs
kubectl logs -n cockroachdb job/flyway-production-migration

# Common issues:
# 1. SQL syntax error - review migration script
# 2. Missing table dependency - ensure migrations run in correct order (V001, V002, V003...)
# 3. Connection timeout - verify Flyway can reach CockroachDB:26257

# Manually apply a migration to test
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production < sql/production/V015__enable_rls_accounts.sql
```

**Problem**: RLS policy syntax error during migration

**Solution**:
```bash
# Test RLS policy manually in SQL shell
kubectl exec -n cockroachdb example-crdb-cluster-0 -it -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production

# In SQL shell:
\d role_party_access

# Test USING clause
SELECT current_setting('app.current_roles', true);

# Manually create policy to debug
CREATE POLICY test_policy ON accounts
  FOR SELECT
  USING (party_id IN (
    SELECT party_id FROM role_party_access
    WHERE role_name = 'advisor-team-east'
  ));
```

### RLS Issues

**Problem**: RLS policy not filtering data

**Solution**:
```bash
# Verify RLS is enabled on table
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production \
    --execute="SELECT tablename, rowsecurity FROM pg_tables WHERE tablename = 'accounts';"

# Ensure FORCE ROW LEVEL SECURITY is set (applies to table owner too)
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production \
    --execute="ALTER TABLE accounts FORCE ROW LEVEL SECURITY;"

# Test session variable setting
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production <<EOF
BEGIN;
SET LOCAL app.current_user = 'test@example.com';
SET LOCAL app.current_roles = 'advisor-team-east';
SELECT current_setting('app.current_user', true), current_setting('app.current_roles', true);
COMMIT;
EOF
```

**Problem**: Users with admin role bypassing RLS unexpectedly

**Solution**: This is expected behavior. Users with `BYPASSRLS` privilege (like admin role) skip RLS policies. This is intentional for batch jobs and admin operations. If you need to test RLS, use a role without BYPASSRLS:

```bash
# Check which roles have BYPASSRLS
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SELECT rolname, rolbypassrls FROM pg_roles WHERE rolbypassrls = true;"

# To revoke BYPASSRLS from a role (use caution):
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="ALTER ROLE admin NOBYPASSRLS;"
```

### Observability Issues

**Problem**: Prometheus not scraping CockroachDB metrics

**Solution**:
```bash
# Check ServiceMonitor exists
kubectl get servicemonitor -n monitoring

# Check Prometheus targets in UI (port-forward to 9090)
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090

# Open http://localhost:9090/targets
# Look for cockroachdb targets - should be UP

# Check network policy allows Prometheus → CockroachDB:8080
kubectl get networkpolicy -n cockroachdb

# Test connectivity from Prometheus pod to CockroachDB metrics endpoint
kubectl exec -n monitoring prometheus-prometheus-kube-prometheus-prometheus-0 -c prometheus -- \
    curl -v http://example-crdb-cluster-0.example-crdb-cluster.cockroachdb:8080/_status/vars
```

**Problem**: Grafana dashboards not showing data

**Solution**:
```bash
# Verify Grafana data source is configured
kubectl exec -n monitoring deployment/prometheus-kube-prometheus-grafana -- \
    curl -s http://admin:prom-operator@localhost:3000/api/datasources | jq .

# Test Prometheus query from Grafana
# In Grafana → Explore → select Prometheus data source
# Query: rate(sql_query_count[5m])

# If no data, check Prometheus is scraping:
# http://localhost:9090/graph?g0.expr=sql_query_count&g0.tab=0

# Re-import dashboards if needed
kubectl apply -f manifests/phase10-observability/grafana-dashboards/
```

### General Debugging

**Enable verbose logging**:

```bash
# CockroachDB - enable SQL statement logging
kubectl exec -n cockroachdb example-crdb-cluster-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SET CLUSTER SETTING sql.trace.log_statement_execute = true;"

# PgBouncer - edit ConfigMap to increase logging
kubectl edit configmap -n cockroachdb pgbouncer-app-config
# Set: log_connections = 1, log_disconnections = 1, log_pooler_errors = 1, verbose = 1

# Restart PgBouncer to apply changes
kubectl rollout restart deployment/pgbouncer-app -n cockroachdb

# Istio - increase log level
kubectl exec -n cockroachdb <pgbouncer-pod> -c istio-proxy -- \
    curl -X POST http://localhost:15000/logging?level=debug
```

**Check resource usage**:

```bash
# Pod resource usage
kubectl top pods -n cockroachdb --containers

# Node resource usage
kubectl top nodes

# Describe pod to see resource limits/requests and current usage
kubectl describe pod -n cockroachdb example-crdb-cluster-0 | grep -A 10 "Requests:\|Limits:"

# Check for OOMKilled pods
kubectl get pods -n cockroachdb -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[*].lastState.terminated.reason}{"\n"}{end}' | grep OOMKilled
```

## Teardown

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

# Delete EKS cluster only (fast cleanup, skips individual phases)
./teardown.sh --cluster-only
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
# Deletes: All phases 13 through 1
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

### Verify AWS Resources are Deleted

After teardown completes, verify that all AWS resources have been removed:

```bash
# Check for remaining EKS clusters
aws eks list-clusters --region us-east-2
aws eks list-clusters --region us-west-2  # If Phase 13 was deployed

# Check for remaining VPCs
aws ec2 describe-vpcs --region us-east-2 --filters "Name=tag:Name,Values=example-crdb-*"

# Check for remaining ELBs/NLBs
aws elb describe-load-balancers --region us-east-2 | jq '.LoadBalancerDescriptions[] | select(.LoadBalancerName | contains("example-crdb"))'
aws elbv2 describe-load-balancers --region us-east-2 | jq '.LoadBalancers[] | select(.LoadBalancerName | contains("example-crdb"))'

# Check for remaining EBS volumes
aws ec2 describe-volumes --region us-east-2 --filters "Name=tag:kubernetes.io/cluster/example-crdb-eks,Values=owned"

# Check for remaining S3 buckets
aws s3 ls | grep example-crdb
```

### Manual Cleanup (if automated teardown fails)

If automated teardown scripts fail, manually delete resources:

```bash
# Delete EKS cluster
eksctl delete cluster --name example-crdb-eks --region us-east-2 --wait

# Delete VPC (if eksctl didn't clean it up)
VPC_ID=$(aws ec2 describe-vpcs --region us-east-2 --filters "Name=tag:Name,Values=example-crdb-vpc" --query 'Vpcs[0].VpcId' --output text)
aws ec2 delete-vpc --vpc-id $VPC_ID --region us-east-2

# Delete S3 buckets (must empty first)
aws s3 rb s3://example-crdb-backups --force
aws s3 rb s3://example-crdb-audit-logs --force

# Delete IAM roles
aws iam list-roles | jq -r '.Roles[] | select(.RoleName | contains("example-crdb")) | .RoleName' | while read role; do
    aws iam delete-role --role-name $role
done
```

## Next Steps

After successful deployment of all phases:

1. **Deploy sample-data-pipeline**: Integrate the Python ETL pipeline from https://github.com/roachlong/sample-data-pipeline
2. **Load production data**: Migrate real data using Flyway or bulk import scripts
3. **Configure monitoring alerts**: Set up PagerDuty/Slack integrations for Alertmanager
4. **Run load tests**: Validate connection pool sizing under realistic load
5. **DR exercise**: Test failover to West cluster (Phase 13)
6. **Security audit**: Pen-testing, vulnerability scanning, compliance review
7. **Performance tuning**: Optimize pool sizes, query plans, indexes based on observability data
8. **Automate operations**: Expand GitOps to cover day-2 operations (scaling, upgrades, backups)

## Additional Resources

- **Architecture**: [ARCHITECTURE.md](./ARCHITECTURE.md)
- **Phase-Specific Guides**:
  - [Phase 4: CockroachDB Cluster](./manifests/phase4-cluster/README.md)
  - [Phase 5: PgBouncer Pools](./manifests/phase5-pgbouncer/README.md)
  - [Phase 6: Istio JWT](./manifests/phase6-istio/README.md)
  - [Phase 7: Flyway Migrations](./manifests/phase7-flyway/README.md)
- **External Documentation**:
  - [CockroachDB Kubernetes Operator](https://www.cockroachlabs.com/docs/stable/orchestrate-cockroachdb-with-kubernetes.html)
  - [CockroachDB Physical Cluster Replication](https://www.cockroachlabs.com/docs/stable/physical-cluster-replication-overview.html)
  - [PgBouncer Documentation](https://www.pgbouncer.org/usage.html)
  - [Istio JWT Authentication](https://istio.io/latest/docs/tasks/security/authentication/authn-policy/#end-user-authentication)
  - [Flyway Documentation](https://flywaydb.org/documentation/)
  - [AWS EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)

## Support

For issues or questions:
- Review the Troubleshooting section above
- Check CockroachDB cluster logs: `kubectl logs -n cockroachdb example-crdb-cluster-0`
- Check PgBouncer logs: `kubectl logs -n cockroachdb deployment/pgbouncer-app`
- Check Istio logs: `kubectl logs -n istio-system deployment/istiod`
- Verify Okta JWT token claims: `echo $JWT_TOKEN | cut -d. -f2 | base64 -d | jq .`
- Test connectivity between components with `kubectl exec ... -- nc -zv <host> <port>`
- Review Grafana dashboards for performance metrics
- Check Prometheus alerts for active issues
