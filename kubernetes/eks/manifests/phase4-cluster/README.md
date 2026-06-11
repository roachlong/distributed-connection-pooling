## Phase 4: CockroachDB Cluster

Deploys a 3-node CockroachDB cluster with JWT authentication, role-based access control, and service accounts. Database infrastructure only - schema objects (tables, RLS policies) are created by Flyway in Phase 7.

## What's Deployed

**CockroachDB Cluster:**
- 3-node CockroachDB StatefulSet (one pod per AZ)
- PersistentVolumeClaims (100Gi gp3 encrypted with KMS)
- TLS enabled with Vault-issued certificates via cert-manager
- Services for SQL access and Admin UI

**Authentication:**
- **JWT Authentication**: Okta OIDC integration via JWKS endpoint
- **Client Certificates**: For service accounts (pgb_app_user, pgb_batch_user, pgb_admin_user, flyway_svc)
- **Cluster Settings**: JWT issuer, audience, JWKS URL, claim mapping

**Databases:**
- `metadata` - Governance data (SOR maps, circuit breakers, batch runs)
- `staging` - Raw landing zone (stg_workday, stg_hubspot, stg_custodian, stg_core_banking)
- `production` - System of Record (accounts, transactions, parties, compliance_events)

**Role Hierarchy:**

*Parent Roles (NOLOGIN):*
- `readonly` - Base read access
- `app` - Application read/write (inherits readonly)
- `pipeline` - Staging schema access for ETL
- `powerbi` - Reporting views only
- `compliance` - Compliance views and audit access
- `developer` - Dev environment access
- `admin` - Full cluster access with BYPASSRLS

*Okta-Mapped Roles (NOLOGIN):*
- `crdb_advisor_team_east` - East region advisors (inherits app, access to East parties)
- `crdb_advisor_team_west` - West region advisors (inherits app, access to West parties)
- `crdb_client_services` - Client services team (read-only accounts)
- `crdb_compliance_team` - Compliance analysts (compliance views)
- `crdb_fiduciary_admin` - Fiduciary administrators (read-write, all parties)
- `crdb_batch_service` - Batch processing (inherits admin, BYPASSRLS)
- `crdb_developers` - Development team (inherits developer)

**Service Account Users (NOLOGIN, certificate-only):**
- `pgb_app_user` - App pool service account (grants: app)
- `pgb_batch_user` - Batch pool service account (grants: admin, BYPASSRLS)
- `pgb_admin_user` - Admin pool service account (grants: admin, BYPASSRLS)
- `flyway_svc` - Schema migrations (grants: admin, BYPASSRLS)

**Certificates:**
- Node certificates (inter-node communication)
- Client certificate: `root` (admin access, for DBA operations)
- Client certificate: `pgb_app_user` (app pool authentication)
- Client certificate: `pgb_batch_user` (batch pool authentication)
- Client certificate: `pgb_admin_user` (admin pool authentication)
- Client certificate: `flyway_svc` (migration tool authentication)
- Automatically managed by cert-manager + Vault PKI

**Services:**
- `${CRDB_CLUSTER_NAME_EAST}-public` - SQL access (port 26257) and Admin UI (port 8080)
- `${CRDB_CLUSTER_NAME_EAST}` - Headless service for StatefulSet

## Prerequisites

- **Phase 0 complete**: Okta OIDC application configured, security groups created
- **Phase 1 complete**: EKS cluster with gp3 encrypted StorageClass
- **Phase 2 complete**: Vault + cert-manager with vault-issuer
- **Phase 3 complete**: CockroachDB Operator installed
- **config.env updated**: Okta configuration values (OKTA_ISSUER, OKTA_CLIENT_ID)
- kubectl installed

## Deployment

### Step 1: Ensure Okta Configuration

Verify that `config.env` contains your Okta configuration from Phase 0:

```bash
grep OKTA ../../config.env
```

Should output (minimum required):
```
export OKTA_ISSUER="https://your-okta-domain/oauth2/default"
export OKTA_CLIENT_ID="your-client-id"

# Optional (defaults to OKTA_CLIENT_ID if not set):
export OKTA_AUDIENCE="${OKTA_CLIENT_ID}"
```

**Notes:**
- `OKTA_JWKS_URL` is auto-derived as `${OKTA_ISSUER}/v1/keys`
- `OKTA_AUDIENCE` defaults to `OKTA_CLIENT_ID` if not specified
- The script fetches JWKS keys dynamically from Okta during setup

### Step 2: Run Setup Script

```bash
cd manifests/phase4-cluster
chmod +x setup.sh
./setup.sh
```

The script will:

1. **Generate Certificates** (cert-manager + Vault PKI):
   - Node certificate (for inter-node TLS)
   - Client certificate: root (admin access)
   - Client certificate: pgb_app_user (app pool)
   - Client certificate: pgb_batch_user (batch pool)
   - Client certificate: pgb_admin_user (admin pool)
   - Client certificate: flyway_svc (schema migrations)

2. **Wait for Certificates to be Ready**

3. **Deploy CrdbCluster Custom Resource**:
   - 3 nodes, 8 CPU limit per node
   - 100Gi persistent storage per node (gp3 encrypted)
   - Pod anti-affinity (one pod per AZ)

4. **Wait for All 3 Pods to be Running** (~5-10 minutes)

5. **Initialize the Cluster** (one-time operation)

6. **Configure JWT Authentication**:
   - Set `server.jwt_authentication.enabled = true`
   - Set `server.jwt_authentication.jwks` to Okta JWKS URL
   - Set `server.jwt_authentication.audience` to configured audience
   - Set `server.jwt_authentication.claim` to `groups`

7. **Create Role Hierarchy**:
   - Create parent roles (readonly, app, pipeline, powerbi, compliance, developer, admin)
   - Grant privileges to parent roles
   - Create Okta-mapped roles (crdb_advisor_team_east, crdb_advisor_team_west, etc.)
   - Grant parent roles to Okta-mapped roles

8. **Create Service Account Users**:
   - Create pgb_app_user (NOLOGIN, grants app role)
   - Create pgb_batch_user (NOLOGIN, grants admin role with BYPASSRLS)
   - Create pgb_admin_user (NOLOGIN, grants admin role with BYPASSRLS)
   - Create flyway_svc (NOLOGIN, grants admin role with BYPASSRLS)

9. **Create Databases**:
   - CREATE DATABASE metadata;
   - CREATE DATABASE staging;
   - CREATE DATABASE production;

10. **Grant Database Permissions**:
    - Grant database-level permissions to roles
    - Grant schema USAGE permissions
    - Note: Table-level permissions and RLS policies will be added by Flyway in Phase 7

11. **Display Connection Information** and validate setup

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

# Certificates should be Ready (6 total)
NAME                                  READY   SECRET                                AGE
cockroachdb-node                      True    cockroachdb-node                      5m
cockroachdb-client-root               True    cockroachdb-client-root               5m
cockroachdb-client-pgb-app-user       True    cockroachdb-client-pgb-app-user       5m
cockroachdb-client-pgb-batch-user     True    cockroachdb-client-pgb-batch-user     5m
cockroachdb-client-pgb-admin-user     True    cockroachdb-client-pgb-admin-user     5m
cockroachdb-client-flyway-svc         True    cockroachdb-client-flyway-svc         5m

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

## JWT Authentication Details

### How JWT Authentication Works

1. **User obtains JWT token from Okta** via OIDC flow
2. **Token contains `groups` claim** with Okta group memberships (e.g., `["crdb_advisor_team_east"]`)
3. **CockroachDB validates JWT token** using Okta's JWKS endpoint
4. **Groups are mapped to roles** automatically:
   - Okta group: `crdb_advisor_team_east`
   - Maps to SQL role: `crdb_advisor_team_east`
   - Which inherits privileges from: `app` role
5. **User is authenticated** with role memberships active

### JWT Token Claims

Required claims in JWT token:
- `iss` (issuer): Must match `OKTA_ISSUER`
- `aud` (audience): Must match `OKTA_AUDIENCE`
- `groups` (custom claim): Array of Okta group names

Example decoded JWT payload:
```json
{
  "iss": "https://dev-12345678.okta.com/oauth2/default",
  "aud": "example-crdb-cluster",
  "sub": "advisor-east@example.com",
  "groups": [
    "crdb_advisor_team_east",
    "crdb_developers"
  ],
  "exp": 1678901234,
  "iat": 1678897634
}
```

### Verifying JWT Configuration

```bash
# Check JWT authentication is enabled
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW CLUSTER SETTING server.jwt_authentication.enabled;"

# Check JWKS URL
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW CLUSTER SETTING server.jwt_authentication.jwks;"

# Check audience
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW CLUSTER SETTING server.jwt_authentication.audience;"

# Check claim (groups)
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW CLUSTER SETTING server.jwt_authentication.claim;"
```

## Connecting to the Cluster

### Method 1: Certificate-Based (Service Accounts, DBAs)

Used by PgBouncer pools, Flyway migrations, and DBA operations.

```bash
# As root (admin access)
kubectl exec -it -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs

# One-liner query as root
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW DATABASES;"
```

### Method 2: Admin UI

Forward the Admin UI port:
```bash
kubectl port-forward -n cockroachdb svc/${CRDB_CLUSTER_NAME_EAST}-public 8080:8080
```

Then access: https://localhost:8080

**Login Methods:**
1. **Certificate-based** (default): Uses root client certificate
2. **Username/password** (if configured):
   ```bash
   kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
       ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
       --execute="CREATE USER dbadmin WITH PASSWORD 'secure-password'; GRANT admin TO dbadmin;"
   ```
   Then login with:
   - Username: dbadmin
   - Password: secure-password

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

### JWT Configuration Issues

**Problem**: JWT configuration not applied

```bash
# Verify JWT cluster settings
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW CLUSTER SETTING server.jwt_authentication.enabled;"
# Expected: true

kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW CLUSTER SETTING server.jwt_authentication.jwks;"
# Expected: Your Okta JWKS JSON

# Test JWKS endpoint accessibility from cluster
kubectl run -n cockroachdb curl-test --image=curlimages/curl:latest --rm -it -- \
    curl -v https://your-okta-domain/oauth2/default/v1/keys
# Should return JSON Web Key Set
```

**Note**: End-to-end JWT authentication testing requires Phase 6 (Istio ingress gateway).

**Problem**: Roles not created

```bash
# Check if roles exist
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW ROLES;"
# Expected: Should show parent roles (readonly, app, admin, etc.) and Okta-mapped roles (crdb_advisor_team_east, etc.)

# Verify role grants
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SHOW GRANTS ON ROLE app;"
# Expected: Should show which roles inherit from app
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

### Phase 5: PgBouncer Connection Pools

Deploy three dedicated PgBouncer connection pools with separate service accounts:
- **App pool** (50%, port 5432): RLS-enforced user connections via `pgb_app_user`
- **Batch pool** (40%, port 5433): Batch jobs with BYPASSRLS via `pgb_batch_user`
- **Admin pool** (10%, port 5434): DBA operations via `pgb_admin_user`

Each pool uses transaction pooling with identity propagation via SET LOCAL session variables.

See [manifests/phase5-pgbouncer/README.md](../phase5-pgbouncer/README.md)

### Phase 6: Istio Service Mesh

Deploy Istio for JWT validation at ingress gateway:
- RequestAuthentication resource (validates Okta JWT tokens)
- AuthorizationPolicy (requires valid JWT)
- Extract groups claim and propagate to PgBouncer as session variables

See [manifests/phase6-istio/README.md](../phase6-istio/README.md)

### Phase 7: Flyway Schema Migrations

Deploy Flyway for automated schema migrations:
- Copy SQL scripts from sample-data-pipeline repository
- Add custom RLS scripts (role_party_access table, full RLS policies)
- Replace stub tables with production schema

See [manifests/phase7-flyway/README.md](../phase7-flyway/README.md)

## Sources

**CockroachDB Documentation:**
- [CockroachDB Operator example.yaml](https://github.com/cockroachdb/cockroach-operator/blob/master/examples/example.yaml)
- [Certificate Management with the CockroachDB Operator](https://www.cockroachlabs.com/docs/stable/secure-cockroachdb-operator)
- [Deploy CockroachDB with the CockroachDB Operator](https://www.cockroachlabs.com/docs/stable/deploy-cockroachdb-with-cockroachdb-operator)
- [JWT Authentication in CockroachDB](https://www.cockroachlabs.com/docs/stable/sso-sql)
- [Row-Level Security](https://www.cockroachlabs.com/docs/stable/row-level-security)
- [Session Variables](https://www.cockroachlabs.com/docs/stable/set-vars)

**Reference Architectures:**
- [ARCHITECTURE.md](../../ARCHITECTURE.md) - Complete system architecture
- [CockroachDB Connectivity Guide](../../generated/references/0.4%20CockroachDB%20Connectivity%20Guide_%20User%20Access%20Design.pdf) - SET LOCAL pattern with transaction pooling
- [Data Access Control](../../generated/references/3.1%20Data%20Access%20Control%20—%20RBAC,%20RLS,%20Column%20Security,%20and%20Okta%20SSO.pdf) - Security layers and role hierarchy

**Sample Data Pipeline:**
- [sample-data-pipeline](https://github.com/roachlong/sample-data-pipeline) - Schema migrations and test data
