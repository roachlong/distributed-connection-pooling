# Phase 5: PgBouncer Connection Pools

Deploys **three dedicated PgBouncer connection pools** with separate service accounts, following the distributed connection pooling best practices for workload isolation and identity propagation.

## What's Deployed

**Three PgBouncer Pools:**

1. **App Pool** (50% of backend connections):
   - Port: 5432
   - Service Account: `pgb_app_user` (grants `app` role)
   - Pool Mode: Transaction
   - Purpose: RLS-enforced user connections from applications
   - Replicas: 3 (configurable via `PGBOUNCER_APP_REPLICAS`)
   - Backend Pool Size: 16 per replica (48 total server connections to CockroachDB)
   - Max Client Connections: 10000 per replica (30000 total incoming client connections)

2. **Batch Pool** (40% of backend connections):
   - Port: 5433
   - Service Account: `pgb_batch_user` (grants `admin` role with BYPASSRLS)
   - Pool Mode: Transaction
   - Purpose: ETL jobs, batch processing, non-RLS workloads
   - Replicas: 2 (configurable via `PGBOUNCER_BATCH_REPLICAS`)
   - Backend Pool Size: 19 per replica (38 total server connections to CockroachDB)
   - Max Client Connections: 10000 per replica (20000 total incoming client connections)

3. **Admin Pool** (10% of backend connections):
   - Port: 5434
   - Service Account: `pgb_admin_user` (grants `admin` role with BYPASSRLS)
   - Pool Mode: Transaction
   - Purpose: DBA operations, monitoring, maintenance scripts
   - Replicas: 1 (configurable via `PGBOUNCER_ADMIN_REPLICAS`)
   - Backend Pool Size: 10 per replica (10 total server connections to CockroachDB)
   - Max Client Connections: 200 per replica (200 total incoming client connections)

**Backend Connection Budget (to CockroachDB):**
- CockroachDB: 3 nodes × 8 CPU limit = 24 total CPUs
- Formula: `4 × num_cpu × num_nodes = 4 × 8 × 3 = 96 total backend connections`
- App pool: 48 backend connections (50%)
- Batch pool: 38 backend connections (40%)
- Admin pool: 10 backend connections (10%)

**Client Connection Capacity (from applications to PgBouncer):**
- App pool: 30000 total client connections (10000 per replica × 3 replicas)
- Batch pool: 20000 total client connections (10000 per replica × 2 replicas)
- Admin pool: 200 total client connections (200 per replica × 1 replica)
- This allows many applications to connect while maintaining controlled backend connections

**Certificates (from Phase 4):**
- `cockroachdb-client-pgb-app-user` - PgBouncer app pool authenticates as `pgb_app_user`
- `cockroachdb-client-pgb-batch-user` - PgBouncer batch pool authenticates as `pgb_batch_user`  
- `cockroachdb-client-pgb-admin-user` - PgBouncer admin pool authenticates as `pgb_admin_user`

**Services:**
- `pgbouncer-app.cockroachdb.svc.cluster.local:5432`
- `pgbouncer-batch.cockroachdb.svc.cluster.local:5433`
- `pgbouncer-admin.cockroachdb.svc.cluster.local:5434`

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Application Clients (RLS-enforced)                                  │
│  - Microservices                                                     │
│  - Web applications                                                  │
│  - Mobile backends                                                   │
└─────────────────┬───────────────────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  App Pool (Port 5432)                                                │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐               │
│  │ PgBouncer 0  │  │ PgBouncer 1  │  │ PgBouncer 2  │               │
│  │ 1K clients   │  │ 1K clients   │  │ 1K clients   │               │
│  │ 16 servers   │  │ 16 servers   │  │ 16 servers   │               │
│  │ pgb_app_user │  │ pgb_app_user │  │ pgb_app_user │               │
│  └──────────────┘  └──────────────┘  └──────────────┘               │
│  Total: 48 server connections                                        │
└─────────────────┬───────────────────────────────────────────────────┘
                  │
                  │ SET LOCAL app.current_user
                  │ SET LOCAL app.current_roles
                  │ (Identity propagation)
                  │
┌─────────────────────────────────────────────────────────────────────┐
│  Batch Clients (BYPASSRLS)                                           │
│  - ETL pipelines (Flyway, sample-data-pipeline)                      │
│  - Data loading scripts                                              │
│  - Batch jobs                                                        │
└─────────────────┬───────────────────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Batch Pool (Port 5433)                                              │
│  ┌──────────────┐  ┌──────────────┐                                 │
│  │ PgBouncer 0  │  │ PgBouncer 1  │                                 │
│  │ 1K clients   │  │ 1K clients   │                                 │
│  │ 19 servers   │  │ 19 servers   │                                 │
│  │ pgb_batch_usr│  │ pgb_batch_usr│                                 │
│  └──────────────┘  └──────────────┘                                 │
│  Total: 38 server connections                                        │
└─────────────────┬───────────────────────────────────────────────────┘
                  │
                  │ No RLS (BYPASSRLS role)
                  │
┌─────────────────────────────────────────────────────────────────────┐
│  Admin Clients (BYPASSRLS)                                           │
│  - DBAs                                                              │
│  - Monitoring tools                                                  │
│  - Maintenance scripts                                               │
└─────────────────┬───────────────────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Admin Pool (Port 5434)                                              │
│  ┌──────────────┐                                                    │
│  │ PgBouncer 0  │                                                    │
│  │ 200 clients  │                                                    │
│  │ 10 servers   │                                                    │
│  │ pgb_admin_usr│                                                    │
│  └──────────────┘                                                    │
│  Total: 10 server connections                                        │
└─────────────────┬───────────────────────────────────────────────────┘
                  │
                  │ Full admin access
                  │
                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  CockroachDB Cluster (3 nodes × 8 CPU)                               │
│  Total server connections: 48 + 38 + 10 = 96                         │
│  (Instead of thousands of direct client connections!)                │
└─────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- **Phase 0 complete**: Okta OIDC application configured
- **Phase 1 complete**: EKS cluster deployed
- **Phase 2 complete**: Vault PKI operational
- **Phase 3 complete**: CockroachDB Operator installed
- **Phase 4 complete**: CockroachDB cluster with service accounts and certificates
  - Service account users: `pgb_app_user`, `pgb_batch_user`, `pgb_admin_user`
  - Client certificates issued via cert-manager + Vault PKI
- kubectl installed

## Deployment

### Step 1: Review Pool Configuration

Verify pool allocation settings in `config.env`:

```bash
cd /path/to/distributed-connection-pooling/kubernetes/eks
grep PGBOUNCER config.env
```

Expected output:
```bash
# App Pool Configuration
export PGBOUNCER_APP_REPLICAS="3"
export PGBOUNCER_APP_POOL_PCT="50"  # Percentage of total backend connections
export PGBOUNCER_APP_PORT="5432"

# Batch Pool Configuration
export PGBOUNCER_BATCH_REPLICAS="2"
export PGBOUNCER_BATCH_POOL_PCT="40"  # Percentage of total backend connections
export PGBOUNCER_BATCH_PORT="5433"

# Admin Pool Configuration
export PGBOUNCER_ADMIN_REPLICAS="1"
export PGBOUNCER_ADMIN_POOL_PCT="10"  # Percentage of total backend connections
export PGBOUNCER_ADMIN_PORT="5434"

# Pool settings (shared across all three pools)
export PGBOUNCER_POOL_MODE="transaction"
export PGBOUNCER_MAX_CLIENT_CONN="10000"  # Client connections for app/batch pools
export PGBOUNCER_ADMIN_MAX_CLIENT_CONN="200"  # Client connections for admin pool
```

### Step 2: Run Setup Script

```bash
cd manifests/phase5-pgbouncer
chmod +x setup.sh
./setup.sh
```

The script will:

1. **Calculate pool sizes** based on formula:
   ```
   Total connections = 4 × 8 CPU × 3 nodes = 96
   App pool size per replica = (96 × 0.50) / 3 replicas = 16
   Batch pool size per replica = (96 × 0.40) / 2 replicas = 19
   Admin pool size per replica = (96 × 0.10) / 1 replica = 10
   ```

2. **Create ConfigMaps** for each pool:
   - `pgbouncer-app-config` (pgbouncer.ini with pool_size=16)
   - `pgbouncer-batch-config` (pgbouncer.ini with pool_size=19)
   - `pgbouncer-admin-config` (pgbouncer.ini with pool_size=10)

3. **Deploy three PgBouncer Deployments**:
   - `pgbouncer-app` (3 replicas, port 5432)
   - `pgbouncer-batch` (2 replicas, port 5433)
   - `pgbouncer-admin` (1 replica, port 5434)

4. **Create three Services**:
   - `pgbouncer-app` (ClusterIP, port 5432)
   - `pgbouncer-batch` (ClusterIP, port 5433)
   - `pgbouncer-admin` (ClusterIP, port 5434)

5. **Wait for all pods to be ready**

6. **Test connections** through each pool

7. **Display connection information**

## Validation

### Check Deployments and Pods

```bash
# Check all PgBouncer pods
kubectl get pods -n cockroachdb -l app=pgbouncer

# Check app pool pods
kubectl get pods -n cockroachdb -l app=pgbouncer,pool=app

# Check batch pool pods
kubectl get pods -n cockroachdb -l app=pgbouncer,pool=batch

# Check admin pool pods
kubectl get pods -n cockroachdb -l app=pgbouncer,pool=admin
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

### Check Services

```bash
kubectl get svc -n cockroachdb | grep pgbouncer
```

Expected output:
```
NAME              TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)    AGE
pgbouncer-app     ClusterIP   10.100.123.45    <none>        5432/TCP   2m
pgbouncer-batch   ClusterIP   10.100.123.46    <none>        5433/TCP   2m
pgbouncer-admin   ClusterIP   10.100.123.47    <none>        5434/TCP   2m
```

### Check Certificates

```bash
kubectl get certificates -n cockroachdb | grep "cockroachdb-client-pgb"
```

Expected output:
```
NAME                                  READY   AGE
cockroachdb-client-pgb-admin-user     True    5m
cockroachdb-client-pgb-app-user       True    5m
cockroachdb-client-pgb-batch-user     True    5m
```

### Test Connections Through Each Pool

```bash
# Test app pool (port 5432)
kubectl run test-psql-app --rm -i --restart=Never --namespace=cockroachdb \
    --image=postgres:16-alpine --command -- \
    psql "postgresql://test@pgbouncer-app:5432/production?sslmode=require" \
    -c "SELECT current_user, current_database();"

# Test batch pool (port 5433)
kubectl run test-psql-batch --rm -i --restart=Never --namespace=cockroachdb \
    --image=postgres:16-alpine --command -- \
    psql "postgresql://test@pgbouncer-batch:5433/production?sslmode=require" \
    -c "SELECT current_user, current_database();"

# Test admin pool (port 5434)
kubectl run test-psql-admin --rm -i --restart=Never --namespace=cockroachdb \
    --image=postgres:16-alpine --command -- \
    psql "postgresql://test@pgbouncer-admin:5434/production?sslmode=require" \
    -c "SELECT current_user, current_database();"
```

Expected output for each pool:
```
  current_user  | current_database 
----------------+------------------
 pgb_app_user   | production       # App pool
 pgb_batch_user | production       # Batch pool
 pgb_admin_user | production       # Admin pool
```

### Check PgBouncer Statistics

```bash
# App pool stats
kubectl exec -n cockroachdb deployment/pgbouncer-app -- \
    psql -h localhost -p 5432 -U pgbouncer pgbouncer -c 'SHOW POOLS;'

# Batch pool stats
kubectl exec -n cockroachdb deployment/pgbouncer-batch -- \
    psql -h localhost -p 5433 -U pgbouncer pgbouncer -c 'SHOW POOLS;'

# Admin pool stats
kubectl exec -n cockroachdb deployment/pgbouncer-admin -- \
    psql -h localhost -p 5434 -U pgbouncer pgbouncer -c 'SHOW POOLS;'
```

Expected columns in output:
- `database`: Database name
- `user`: Service account user (pgb_app_user, pgb_batch_user, pgb_admin_user)
- `cl_active`: Active client connections
- `cl_waiting`: Clients waiting for a connection (should be 0)
- `sv_active`: Active server connections to CockroachDB
- `sv_idle`: Idle server connections
- `maxwait`: Maximum wait time

## Connection Strings for Applications

### App Pool (RLS-Enforced User Connections)

**Use Case**: Microservices, web applications, mobile backends that require Row-Level Security

**Connection String**:
```
postgresql://pgb_app_user@pgbouncer-app.cockroachdb.svc.cluster.local:5432/production?sslmode=require
```

**Note:** With `auth_type=any`, the username can be anything - PgBouncer authenticates to CockroachDB as `pgb_app_user` regardless. Using the service account name in the connection string makes it clear which backend user is being used.

**Application Pattern** (middleware injects user identity):
```python
import psycopg

conn = psycopg.connect(
    "postgresql://pgb_app_user@pgbouncer-app:5432/production?sslmode=require",
    sslcert="/path/to/client.root.crt",
    sslkey="/path/to/client.root.key",
    sslrootcert="/path/to/ca.crt"
)
conn.autocommit = False

try:
    cursor = conn.cursor()
    cursor.execute("BEGIN;")
    # Inject user identity from JWT token
    cursor.execute("SET LOCAL app.current_user = %s;", (user_email,))
    cursor.execute("SET LOCAL app.current_roles = %s;", (user_roles,))
    
    # Business queries execute with RLS filtering
    cursor.execute("SELECT * FROM accounts WHERE account_status = 'active';")
    results = cursor.fetchall()
    
    conn.commit()  # SET LOCAL variables cleared
except Exception as e:
    conn.rollback()
    raise
finally:
    conn.close()
```

### Batch Pool (BYPASSRLS for ETL Jobs)

**Use Case**: Flyway migrations, ETL pipelines, data loading scripts, batch processing

**Connection String**:
```
postgresql://pgb_batch_user@pgbouncer-batch.cockroachdb.svc.cluster.local:5433/production?sslmode=require
```

**Example Usage** (Python ETL script):
```python
# Backend authenticates as pgb_batch_user (has BYPASSRLS privilege)
import psycopg

conn = psycopg.connect(
    "postgresql://pgb_batch_user@pgbouncer-batch:5433/staging?sslmode=require",
    sslcert="/path/to/client.root.crt",
    sslkey="/path/to/client.root.key",
    sslrootcert="/path/to/ca.crt"
)

# No SET LOCAL needed - batch operations see all rows
cursor = conn.cursor()
cursor.execute("INSERT INTO staging.stg_workday SELECT * FROM source_table;")
conn.commit()
```

### Admin Pool (DBA Operations)

**Use Case**: Database administration, monitoring tools, maintenance scripts

**Connection String**:
```
postgresql://pgb_admin_user@pgbouncer-admin.cockroachdb.svc.cluster.local:5434/defaultdb?sslmode=require
```

**Example Usage** (cockroach sql CLI):
```bash
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql \
    --url "postgresql://pgb_admin_user@pgbouncer-admin:5434/defaultdb?sslmode=require" \
    --certs-dir=/cockroach/cockroach-certs
```

## Identity Propagation with Transaction Pooling

### How It Works

PgBouncer's **transaction pooling mode** allows backend connections to be shared across multiple users while maintaining per-user identity through session variables.

**Key Pattern**:
1. **Application obtains user identity** from JWT token (email, roles)
2. **Application starts explicit transaction**: `BEGIN;`
3. **Middleware injects session variables** (transaction-scoped):
   ```sql
   SET LOCAL app.current_user = 'advisor.east@example.com';
   SET LOCAL app.current_roles = 'crdb_advisor_team_east';
   ```
4. **Business queries execute** with RLS filtering active
5. **Transaction commits**: `COMMIT;`
6. **Session variables cleared automatically** (`SET LOCAL` is transaction-scoped)
7. **PgBouncer returns connection to pool** for next user

**Safety Guarantees**:
- `SET LOCAL` variables are **transaction-scoped** (cleared at COMMIT/ROLLBACK)
- No credential leakage between users sharing same backend connection
- Transaction pooling maintains connection efficiency
- RLS policies read `current_setting('app.current_user')` and `current_setting('app.current_roles')`

### Why Three Pools?

**Workload Isolation**:
- **App pool**: User-facing queries with RLS overhead (read-mostly, latency-sensitive)
- **Batch pool**: Bulk operations without RLS (write-heavy, throughput-optimized)
- **Admin pool**: Ad-hoc queries and maintenance (unpredictable, low volume)

**Security Isolation**:
- App pool uses `pgb_app_user` (grants `app` role, RLS enforced)
- Batch pool uses `pgb_batch_user` (grants `admin` role with BYPASSRLS)
- Admin pool uses `pgb_admin_user` (grants `admin` role with BYPASSRLS)

**Resource Allocation**:
- 50% app (user-facing, highest priority)
- 40% batch (bulk operations, second priority)
- 10% admin (maintenance, lowest priority)

## Configuration Details

### PgBouncer Settings (from Terraform DCP Module)

All three pools share the same base configuration:

```ini
[pgbouncer]
# Connection pooling
pool_mode = transaction              # Shares backend connections across users
max_client_conn = 10000             # Incoming client connections per replica (200 for admin pool)
default_pool_size = <calculated>    # Backend connections to CockroachDB: varies by pool (16, 19, or 10)
reserve_pool_size = <calculated>    # Emergency backend connections (pool_size / 4)

# Authentication
auth_type = any                     # Accept any client username, backend auth as forced user
auth_user = <service_account>       # pgb_app_user, pgb_batch_user, or pgb_admin_user

# TLS - Server side (PgBouncer → CockroachDB)
server_tls_sslmode = require
server_tls_ca_file = /cockroach-certs/ca.crt
server_tls_key_file = /cockroach-certs/tls.key
server_tls_cert_file = /cockroach-certs/tls.crt

# TLS - Client side (Applications → PgBouncer)
client_tls_sslmode = allow          # Accept both TLS and non-TLS clients
client_tls_ca_file = /cockroach-certs/ca.crt
client_tls_key_file = /cockroach-certs/tls.key
client_tls_cert_file = /cockroach-certs/tls.crt

# Performance tuning (from Terraform DCP)
so_reuseport = 1                    # Port reuse for concurrency
listen_backlog = 4096               # Connection queue depth
server_round_robin = 1              # Load balance across backends

# Logging
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1

# Timeouts (disabled for load testing)
server_idle_timeout = 0
server_lifetime = 0
server_connect_timeout = 15
query_timeout = 0
query_wait_timeout = 120
client_idle_timeout = 0
idle_transaction_timeout = 0
```

### Pool Size Calculation

**Formula**: `4 × cpu_limit × node_count × pool_pct / replicas`

**Example for app pool**:
```
Total connections = 4 × 8 CPU × 3 nodes = 96
App allocation = 96 × 0.50 = 48 connections
App replicas = 3
Pool size per replica = 48 / 3 = 16 server connections
```

**Verification**:
```bash
# Check calculated pool sizes in setup script output
cd manifests/phase5-pgbouncer
./setup.sh | grep "Pool Size Calculation"

# Verify ConfigMap pool sizes
kubectl get configmap -n cockroachdb pgbouncer-app-config -o yaml | grep default_pool_size
kubectl get configmap -n cockroachdb pgbouncer-batch-config -o yaml | grep default_pool_size
kubectl get configmap -n cockroachdb pgbouncer-admin-config -o yaml | grep default_pool_size
```

## Reconfiguring Pools

### Changing Pool Allocation

Edit `config.env` and update percentages:

```bash
vi config.env

# Change allocations (must sum to 100%)
export PGBOUNCER_APP_POOL_PCT="60"    # Was 50%
export PGBOUNCER_BATCH_POOL_PCT="30"  # Was 40%
export PGBOUNCER_ADMIN_POOL_PCT="10"  # Stays 10%

# Re-run setup to apply changes
cd manifests/phase5-pgbouncer
./teardown.sh
./setup.sh
```

### Scaling Pool Replicas

Scale individual pools independently:

```bash
# Scale app pool for more client capacity
kubectl scale deployment pgbouncer-app -n cockroachdb --replicas=5

# Note: This changes pool size per replica!
# Old: 48 total / 3 replicas = 16 per replica
# New: 48 total / 5 replicas = 9.6 → rounds to 10 per replica

# Update ConfigMap to reflect new pool size
# (Or re-run setup.sh with updated PGBOUNCER_APP_REPLICAS in config.env)
```

### Monitoring Configuration Changes

Stakater Reloader automatically restarts pods when ConfigMaps change:

```bash
# Edit ConfigMap (e.g., change pool_size)
kubectl edit configmap pgbouncer-app-config -n cockroachdb

# Reloader detects change and restarts pods automatically
# Watch rollout:
kubectl rollout status deployment/pgbouncer-app -n cockroachdb
```

## Monitoring

### Key Metrics to Watch

For each pool, monitor:

1. **cl_waiting** (clients waiting for connection): Should be 0
   - If > 0: Pool exhaustion, increase `default_pool_size` or `replicas`

2. **sv_active** (active server connections): Should be < `default_pool_size`
   - If == pool_size: All connections in use, may need more capacity

3. **maxwait** (maximum wait time in seconds): Should be 0
   - If > 0: Clients are queuing, increase pool capacity

4. **avg_query_time** (average query duration): Track performance
   - Sudden increases may indicate slow queries or backend issues

### Real-Time Monitoring

```bash
# Watch app pool stats
watch -n 2 "kubectl exec -n cockroachdb deployment/pgbouncer-app -- \
    psql -h localhost -p 5432 -U pgbouncer pgbouncer -c 'SHOW POOLS;'"

# Compare all three pools
for pool in app batch admin; do
  echo "=== $pool pool ==="
  PORT=$(grep PGBOUNCER_${pool^^}_PORT config.env | cut -d= -f2 | tr -d '"')
  kubectl exec -n cockroachdb deployment/pgbouncer-$pool -- \
      psql -h localhost -p $PORT -U pgbouncer pgbouncer -c 'SHOW POOLS;'
done
```

### PgBouncer Admin Commands

```bash
# Connect to app pool admin console
kubectl exec -it -n cockroachdb deployment/pgbouncer-app -- \
    psql -h localhost -p 5432 -U pgbouncer pgbouncer

# Useful commands:
SHOW POOLS;           # Pool statistics
SHOW CLIENTS;         # Client connections
SHOW SERVERS;         # Server connections to CockroachDB
SHOW DATABASES;       # Database configuration
SHOW STATS;           # Request statistics
RELOAD;               # Reload configuration (after ConfigMap edit)
PAUSE <database>;     # Pause connections to a database
RESUME <database>;    # Resume connections
KILL <database>;      # Kill all connections to a database
```

## Troubleshooting

### Pods Not Starting

```bash
# Check pod events for specific pool
kubectl describe pod -n cockroachdb -l app=pgbouncer,pool=app

# Check logs
kubectl logs -n cockroachdb -l app=pgbouncer,pool=app

# Common issues:
# 1. ConfigMap not found
kubectl get configmap -n cockroachdb | grep pgbouncer

# 2. Certificate errors - verify secrets exist
kubectl get secret -n cockroachdb | grep pgbouncer

# 3. Service account user not created in CockroachDB (Phase 4)
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SELECT username FROM system.users WHERE username LIKE 'pgb_%';"
```

### Connection Failures

```bash
# Test backend connectivity from PgBouncer pod
kubectl exec -n cockroachdb deployment/pgbouncer-app -- \
    nc -zv ${CRDB_CLUSTER_NAME_EAST}-public 26257

# Verify certificates are mounted correctly
kubectl exec -n cockroachdb deployment/pgbouncer-app -- \
    ls -la /cockroach/cockroach-certs/ /pgbouncer-certs/

# Check PgBouncer logs for authentication errors
kubectl logs -n cockroachdb -l app=pgbouncer,pool=app | grep -i "authentication\|error\|failed"

# Test direct CockroachDB connection (bypass PgBouncer)
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs --execute="SELECT 1;"
```

### Pool Exhaustion (cl_waiting > 0)

```bash
# Check which pool is exhausted
kubectl exec -n cockroachdb deployment/pgbouncer-app -- \
    psql -h localhost -p 5432 -U pgbouncer pgbouncer -c "SHOW POOLS;" | grep -v "^$"

# Solutions:
# 1. Increase pool size per replica
vi config.env
export PGBOUNCER_APP_POOL_PCT="60"  # Increase from 50%
./teardown.sh && ./setup.sh

# 2. Scale replicas (decreases pool size per replica, increases client capacity)
kubectl scale deployment pgbouncer-app -n cockroachdb --replicas=5

# 3. Optimize application connection usage
# - Use connection pooling in application layer
# - Close connections promptly after use
# - Reduce connection lifetime
```

### Pool Size Mismatch Warning

During setup, you may see:
```
⚠ Pool size mismatch! Expected 16, configured 20
```

This means manual changes were made to `config.env` that don't match the formula.

**Fix**:
```bash
# Recalculate manually:
# Total = 4 × CPU_LIMIT × NODE_COUNT = 4 × 8 × 3 = 96
# App = 96 × 0.50 = 48
# Per replica = 48 / 3 = 16

# Update config.env to match
vi config.env
export PGBOUNCER_APP_DEFAULT_POOL_SIZE="16"  # Not 20
export PGBOUNCER_BATCH_DEFAULT_POOL_SIZE="19"
export PGBOUNCER_ADMIN_DEFAULT_POOL_SIZE="10"

# Re-run setup
./teardown.sh && ./setup.sh
```

### Service Account Authentication Failures

**Problem**: PgBouncer cannot authenticate to CockroachDB as service account user

```bash
# Verify service account user exists
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="SELECT username, \"isRole\" FROM system.users WHERE username IN ('pgb_app_user', 'pgb_batch_user', 'pgb_admin_user');"

# Expected output:
#     username      | isRole
# ------------------+--------
#   pgb_admin_user  | false
#   pgb_app_user    | false
#   pgb_batch_user  | false

# Verify client certificate CN matches service account username
kubectl get secret -n cockroachdb cockroachdb-client-pgb-app-user -o yaml | grep 'tls.crt' | awk '{print $2}' | base64 -d | openssl x509 -noout -subject
# Should show: subject=CN=pgb_app_user
```

## Teardown

```bash
cd ../..
./teardown.sh --phase 5
```

This will remove:
- Three PgBouncer Deployments (app, batch, admin)
- Three PgBouncer Services
- Three ConfigMaps (pgbouncer-app-config, pgbouncer-batch-config, pgbouncer-admin-config)

**Note**: This does not affect:
- CockroachDB cluster
- Service account users in CockroachDB (pgb_app_user, pgb_batch_user, pgb_admin_user)
- Vault PKI or cert-manager

## Next Steps

### Phase 6: Istio Service Mesh

Deploy Istio for JWT validation at ingress gateway:
- Validate Okta JWT tokens before reaching PgBouncer
- Extract `groups` claim from JWT
- Propagate user identity to PgBouncer app pool
- Enforce JWT requirement for external traffic

See [manifests/phase6-istio/README.md](../phase6-istio/README.md)

### Phase 7: Flyway Schema Migrations

Deploy Flyway for automated schema migrations:
- Copy SQL scripts from sample-data-pipeline repository
- Replace stub tables with full production schema
- Add comprehensive RLS policies on accounts and parties tables
- Flyway connects to batch pool (port 5433) for DDL operations

See [manifests/phase7-flyway/README.md](../phase7-flyway/README.md)

## References

**Architecture Documentation:**
- [ARCHITECTURE.md](../../ARCHITECTURE.md) - Complete system architecture
- [CockroachDB Connectivity Guide](../../generated/references/0.4%20CockroachDB%20Connectivity%20Guide_%20User%20Access%20Design.pdf) - Three-pool design and SET LOCAL pattern

**CockroachDB Documentation:**
- [Connection Pooling Best Practices](https://www.cockroachlabs.com/docs/stable/connection-pooling)
- [Transaction Pooling vs Session Pooling](https://www.cockroachlabs.com/docs/stable/connection-pooling#transaction-pooling-vs-session-pooling)

**PgBouncer Documentation:**
- [PgBouncer Configuration](https://www.pgbouncer.org/config.html)
- [PgBouncer Admin Console](https://www.pgbouncer.org/usage.html#admin-console)

**Reference Implementations:**
- [Terraform DCP Module](https://github.com/roachlong/distributed-connection-pooling/tree/main/terraform/aws/modules/dcp) - Original EC2-based implementation
- [sample-data-pipeline](https://github.com/roachlong/sample-data-pipeline) - ETL pipeline using batch pool
