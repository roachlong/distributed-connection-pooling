# EKS Reference Architecture: Distributed Connection Pooling with Row-Level Security

## Overview

This reference architecture implements a production-ready, multi-tenant CockroachDB deployment on AWS EKS with:
- **Distributed Connection Pooling** - Three-tier PgBouncer pools (app, batch, admin)
- **JWT-based Authentication** - Okta/WSOC OIDC integration with auto-provisioning
- **Row-Level Security (RLS)** - Role-based party access with middleware-injected session context
- **Zero-downtime Schema Migrations** - Flyway with direct CockroachDB connections
- **Service Mesh Security** - Istio for JWT validation and request routing

## System Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  Client Layer                                                         │
│  • End Users (Browser → Okta OIDC → JWT)                            │
│  • Python Pipeline Scripts (Service Account Credentials)             │
│  • DBA Tools (psql, DBeaver with Okta JWT)                          │
│  • Power BI (Phase 10 - connects to PCR West standby)               │
└────────────────────────────┬─────────────────────────────────────────┘
                             │
                             ↓
┌──────────────────────────────────────────────────────────────────────┐
│  Istio Service Mesh (Phase 6)                                        │
│  • RequestAuthentication: Validates JWT against Okta JWKS           │
│  • Extracts claims: email → x-user-email, groups → x-user-groups    │
│  • AuthorizationPolicy: Requires valid JWT for app pool traffic     │
│  • Sidecar injection on PgBouncer pods                              │
└────────────────────────────┬─────────────────────────────────────────┘
                             │
                             ↓
┌──────────────────────────────────────────────────────────────────────┐
│  Application Middleware Layer                                        │
│  • Reads x-user-email and x-user-groups headers                     │
│  • Normalizes Okta group names to CockroachDB role names            │
│  • Wraps transactions:                                               │
│      BEGIN;                                                          │
│      SET LOCAL app.current_user = 'alice@example.com';              │
│      SET LOCAL app.current_roles = 'crdb_advisor_team_east,crdb_compliance_team';  │
│      -- Business queries execute here --                             │
│      COMMIT;  -- Session variables auto-cleared                     │
└────────────────────────────┬─────────────────────────────────────────┘
                             │
          ┌──────────────────┼──────────────────┐
          │                  │                  │
          ↓                  ↓                  ↓
    ┌─────────┐        ┌─────────┐       ┌─────────┐
    │   App   │        │  Batch  │       │  Admin  │   PgBouncer Pools
    │  :5432  │        │  :5433  │       │  :5434  │   (Phase 5)
    │  50%    │        │  40%    │       │  10%    │
    │  3 pods │        │  2 pods │       │  1 pod  │
    └────┬────┘        └────┬────┘       └────┬────┘
         │                  │                  │
         │  Transaction     │  Transaction     │  Transaction
         │  Pooling         │  Pooling         │  Pooling
         │  pgb_app_user    │  pgb_batch_user  │  pgb_admin_user
         │  (fiduciary_ops) │  (batch_svc)     │  (fiduciary_admin)
         │  RLS enforced    │  BYPASSRLS       │  BYPASSRLS
         │                  │                  │
         └──────────────────┼──────────────────┘
                            │ mTLS (Vault-issued certificates)
                            ↓
┌──────────────────────────────────────────────────────────────────────┐
│  CockroachDB Cluster - Primary East (Phase 4)                       │
│  • 3 nodes × 8 CPU = 96 total connections (4 × CPU × nodes)         │
│  • JWT auto-provisioning enabled (security.provisioning.jwt)        │
│  • Parent roles: readonly, app, pipeline, powerbi, compliance, developer, admin  │
│  • Okta-mapped roles: crdb_advisor_team_east, crdb_compliance_team, etc.  │
│  • RLS policies on accounts & parties tables                        │
│  • Three databases: metadata, staging, production                   │
│  • Vault PKI for all TLS certificates                               │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│  Flyway Schema Migrations (Phase 7)                                 │
│  • Kubernetes Job (runs on-demand or scheduled)                     │
│  • Bypasses PgBouncer - connects directly to :26257                 │
│  • Uses flyway_svc certificate (fiduciary_admin role)               │
│  • Migrates metadata, staging, production databases                 │
└──────────────────────────────────────────────────────────────────────┘
```

## Connection Pooling Strategy

### Total Capacity Calculation

```
Total Backend Connections = 4 × CPU_LIMIT × NODE_COUNT
                         = 4 × 8 × 3
                         = 96 connections
```

### Pool Allocation

| Pool | Percentage | Total Conns | Replicas | Per-Replica | Port | Mode | Service Account | Role | RLS |
|------|------------|-------------|----------|-------------|------|------|----------------|------|-----|
| App | 50% | 48 | 3 | 16 | 5432 | transaction | pgb_app_user | fiduciary_ops | ✅ Yes |
| Batch | 40% | 38 | 2 | 19 | 5433 | transaction | pgb_batch_user | batch_svc | ❌ BYPASSRLS |
| Admin | 10% | 10 | 1 | 10 | 5434 | transaction | pgb_admin_user | fiduciary_admin | ❌ BYPASSRLS |

### Dynamic Reconfiguration

Pool allocation is configurable via `config.env` percentages:

```bash
# Adjust percentages (must sum to 100)
export PGBOUNCER_APP_POOL_PCT="50"
export PGBOUNCER_BATCH_POOL_PCT="40"
export PGBOUNCER_ADMIN_POOL_PCT="10"

# Rerun setup to apply changes
cd manifests/phase5-pgbouncer && ./setup.sh
```

PgBouncer pods restart with updated pool sizes. ConfigMap Reloader automatically detects changes.

## Security Model

### Two Authentication Paths

#### 1. Pooled Access (App + Batch Pools)

**Use Cases:**
- End-user queries through applications
- Python pipeline scripts (merge_to_production.py, load_staging.py)
- Circuit breaker APIs

**Flow:**
1. User authenticates to Okta → receives JWT
2. Istio validates JWT, extracts `email` and `groups` claims
3. Application middleware reads headers, normalizes groups to roles
4. Middleware wraps transaction:
   ```sql
   BEGIN;
   SET LOCAL app.current_user = 'alice@example.com';
   SET LOCAL app.current_roles = 'crdb_advisor_team_east,crdb_compliance_team';
   -- Business queries execute here
   COMMIT;  -- Variables automatically cleared
   ```
5. RLS policies evaluate `current_setting('app.current_user')` and `current_setting('app.current_roles')`
6. User sees only rows for parties their roles grant access to

**No CockroachDB user per human** - users authenticate at the application layer, not the database layer.

#### 2. Direct Access (Admin Pool + Developer Tooling)

**Use Cases:**
- DBAs using psql or DBeaver
- Developers running ad-hoc queries
- Break-glass access scenarios

**Flow:**
1. Developer authenticates to Okta → receives JWT
2. Connects directly to CockroachDB (or via admin pool):
   ```bash
   cockroach sql \
     --url "postgresql://alice@example.com@cockroachdb-public:26257/production" \
     --certs-dir=/certs \
     --password  # Paste JWT as password
   ```
3. CockroachDB validates JWT via native `server.jwt_authentication` settings
4. Auto-provisions SQL user `alice@example.com` on first login
5. Grants roles based on JWT `groups` claim
6. User queries with their assigned role privileges

### Row-Level Security (RLS) Design

#### Okta Groups → CockroachDB Roles → Party Access

**Mapping Architecture:**

```
Okta Groups                CockroachDB Roles         Party Access
━━━━━━━━━━━                ━━━━━━━━━━━━━━━━━         ━━━━━━━━━━━━
crdb_advisor_team_east     crdb_advisor_team_east →  [party_id_1, party_id_2, ...]
                                 ↓
                          (inherits)
                                 ↓
                          app                  →    (base permissions on production schema)
```

**Database Tables:**

```sql
-- Maps roles to accessible party IDs
CREATE TABLE role_party_access (
    role_name STRING NOT NULL,
    party_id UUID NOT NULL REFERENCES parties(party_id),
    access_level STRING NOT NULL,  -- 'read_only', 'read_write'
    granted_at TIMESTAMPTZ DEFAULT now(),
    granted_by STRING,
    PRIMARY KEY (role_name, party_id)
);

-- Example data
INSERT INTO role_party_access (role_name, party_id, access_level, granted_by) VALUES
  ('crdb_advisor_team_east', '123e4567-...', 'read_write', 'admin'),
  ('crdb_advisor_team_east', '234e5678-...', 'read_write', 'admin'),
  ('crdb_compliance_team', '345e6789-...', 'read_only', 'audit-manager');
```

**RLS Policies:**

```sql
-- Enable RLS on accounts table
ALTER TABLE accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE accounts FORCE ROW LEVEL SECURITY;

-- Policy: Users can only access accounts for parties their roles grant access to
CREATE POLICY role_based_account_access ON accounts
  FOR ALL
  USING (
    current_setting('app.current_user', true) != ''
    AND current_setting('app.current_roles', true) != ''
    AND party_id IN (
      SELECT party_id FROM role_party_access
      WHERE role_name = ANY(string_to_array(current_setting('app.current_roles', true), ','))
    )
  )
  WITH CHECK (
    current_setting('app.current_user', true) != ''
    AND current_setting('app.current_roles', true) != ''
    AND party_id IN (
      SELECT party_id FROM role_party_access
      WHERE role_name = ANY(string_to_array(current_setting('app.current_roles', true), ','))
        AND access_level = 'read_write'
    )
  );

-- Batch and admin bypass RLS
ALTER ROLE batch_svc BYPASSRLS;
ALTER ROLE fiduciary_admin BYPASSRLS;
```

**RLS Cascading:**

RLS on `accounts` automatically filters joined tables:

```sql
-- Query joins accounts → transactions
SELECT 
    a.account_number,
    t.transaction_id,
    t.amount
FROM accounts a
JOIN transactions t ON t.account_id = a.account_id;

-- RLS filters accounts first based on party_id
-- Only transactions for accessible accounts are returned
-- No explicit RLS needed on transactions table!
```

**Where to Apply RLS:**
- ✅ `accounts` - primary access control point (filters by party_id)
- ✅ `parties` - users should only see parties they manage
- ❌ `transactions` - automatically filtered via account_id FK
- ❌ `compliance_events` - automatically filtered via account_id FK
- ❌ `metadata`, `staging` - no RLS (service accounts only)

### Service Account Roles

| Account | Pool | Role | Privileges | RLS |
|---------|------|------|------------|-----|
| pgb_app_user | App | fiduciary_ops | SELECT, INSERT, UPDATE, DELETE on production schema | ✅ Enforced via session variables |
| pgb_batch_user | Batch | batch_svc | Full access to metadata, staging, production | ❌ BYPASSRLS (ETL needs full table access) |
| pgb_admin_user | Admin | fiduciary_admin | Full cluster access, DDL, DML, backups | ❌ BYPASSRLS (DBA operations) |
| flyway_svc | Direct | fiduciary_admin | DDL, schema migrations | ❌ BYPASSRLS (bypasses PgBouncer) |

## Component Access Patterns

### sample-data-pipeline Integration

| Component | Pool | Port | Service Account | RLS | Purpose |
|-----------|------|------|----------------|-----|---------|
| merge_to_production.py | Batch | 5433 | pgb_batch_user | No | Pattern 3: Staging → Production MERGE |
| load_staging.py | Batch | 5433 | pgb_batch_user | No | Pattern 1 & 2: Load staging tables |
| evaluate_circuit_breakers.py | App | 5432 | pgb_app_user | No | Metadata queries (no RLS tables) |
| circuit_breaker_api.py | App | 5432 | pgb_app_user | No | Read metadata.circuit_breaker_rules |
| End-user queries | App | 5432 | pgb_app_user | **Yes** | Application-layer queries with RLS |
| DBA operations | Admin | 5434 | pgb_admin_user | No | Manual queries, troubleshooting |
| Flyway migrations | Direct | 26257 | flyway_svc | No | Schema DDL (bypasses PgBouncer) |
| Power BI (Phase 10) | Analytics | 5435 | pgb_analytics_user | Partial | Connects to PCR West, pre-filtered views |

### Why Flyway Bypasses PgBouncer

**Problem:** DDL operations incompatible with transaction pooling

```ini
# PgBouncer transaction mode
pool_mode = transaction
server_reset_query = RESET ALL

# Issue: Connection released after each transaction
# DDL operations span multiple transactions
# Flyway loses connection mid-migration
```

**Solution:** Direct connection to CockroachDB

```bash
# Flyway connects directly to CockroachDB on port 26257
jdbc:postgresql://cockroachdb-public.cockroachdb.svc.cluster.local:26257/production
```

**Benefits:**
- ✅ Reliable DDL execution
- ✅ No connection drops mid-migration
- ✅ Leverages CockroachDB's online schema change engine
- ✅ Zero downtime for production traffic

## Database Schema Structure

### Three Separate Databases

| Database | Purpose | Tables | Locality | Accessed By |
|----------|---------|--------|----------|-------------|
| metadata | Governance, SOR mappings, circuit breakers | entity_sor_map, batch_runs, dq_violations, circuit_breaker_rules, role_party_access | GLOBAL | All pools |
| staging | Raw data landing zone | stg_workday, stg_hubspot, stg_custodian, stg_core_banking, stg_compliance_events | REGIONAL BY TABLE | Batch pool |
| production | System of record | accounts, transactions, parties, compliance_events, currencies, regulatory_codes | REGIONAL BY TABLE or REGIONAL BY ROW | All pools |

### Key Production Tables

**accounts** (REGIONAL BY TABLE):
```sql
CREATE TABLE accounts (
    account_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    party_id UUID NOT NULL REFERENCES parties(party_id),
    account_number STRING NOT NULL,
    account_type STRING NOT NULL,  -- CHECKING, SAVINGS, CUSTODY, etc.
    account_status STRING NOT NULL, -- ACTIVE, SUSPENDED, CLOSED
    balance DECIMAL(18,2),
    currency_code STRING NOT NULL REFERENCES currencies(currency_code),
    -- Provenance columns
    source_system STRING NOT NULL,
    source_record_id STRING NOT NULL,
    load_timestamp TIMESTAMPTZ DEFAULT now(),
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE accounts SET LOCALITY REGIONAL BY TABLE IN PRIMARY REGION;
ALTER TABLE accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE accounts FORCE ROW LEVEL SECURITY;
```

**parties** (REGIONAL BY TABLE):
```sql
CREATE TABLE parties (
    party_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    party_type STRING NOT NULL,  -- INDIVIDUAL, ORGANIZATION
    first_name STRING,
    last_name STRING,
    organization_name STRING,
    email STRING,
    phone STRING,
    tax_id STRING,
    source_system STRING NOT NULL,
    source_record_id STRING NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE parties SET LOCALITY REGIONAL BY TABLE IN PRIMARY REGION;
ALTER TABLE parties ENABLE ROW LEVEL SECURITY;
ALTER TABLE parties FORCE ROW LEVEL SECURITY;
```

## Phase Dependencies

```
Phase 1: Foundation (EKS, S3, KMS)
    ↓
Phase 2: Certificates (Vault PKI, cert-manager)
    ├─ Vault PKI with service account domains:
    │  pgb_app_user, pgb_batch_user, pgb_admin_user, flyway_svc
    ↓
Phase 3: CockroachDB Operator
    ↓
Phase 4: CockroachDB Cluster
    ├─ Enable JWT authentication (Okta JWKS)
    ├─ Create parent roles (readonly, app, pipeline, powerbi, compliance, developer, admin)
    ├─ Create Okta-mapped roles (crdb_advisor_team_east, crdb_compliance_team, etc.)
    ├─ Create service accounts (pgb_*_user, flyway_svc)
    ├─ Create databases (metadata, staging, production)
    ↓
Phase 5: PgBouncer (Three Pools)
    ├─ App Pool (50%, port 5432, pgb_app_user)
    ├─ Batch Pool (40%, port 5433, pgb_batch_user)
    └─ Admin Pool (10%, port 5434, pgb_admin_user)
    ↓
Phase 6: Istio Service Mesh
    ├─ RequestAuthentication (validates JWT against Okta)
    ├─ AuthorizationPolicy (require JWT for app pool)
    └─ Sidecar injection on PgBouncer pods
    ↓
Phase 7: Flyway Schema Migrations
    ├─ Deploy sample-data-pipeline schema (V001-V014)
    ├─ Add RLS tables and policies (V015-V016)
    ├─ Bypasses PgBouncer, connects to :26257
    ↓
Phase 8-9: Security, Observability (unchanged)
    ↓
Phase 10: Physical Cluster Replication (PCR)
    ├─ Deploy West standby cluster
    ├─ Add Analytics Pool (100% of West capacity, port 5435)
    └─ Deploy Power BI client
```

## Connection Strings

### Application (Python Scripts)

```python
# Via App Pool (RLS enforced for end-user queries)
import psycopg

conn = psycopg.connect(
    host="pgbouncer-app.cockroachdb.svc.cluster.local",
    port=5432,
    dbname="production",
    user="pgb_app_user",
    sslmode="require",
    sslcert="/certs/client.crt",
    sslkey="/certs/client.key",
    sslrootcert="/certs/ca.crt"
)
```

```python
# Via Batch Pool (BYPASSRLS for ETL scripts)
conn = psycopg.connect(
    host="pgbouncer-batch.cockroachdb.svc.cluster.local",
    port=5433,
    dbname="staging",
    user="pgb_batch_user",
    sslmode="require",
    sslcert="/certs/client.crt",
    sslkey="/certs/client.key",
    sslrootcert="/certs/ca.crt"
)
```

### DBA (psql)

```bash
# Via Admin Pool
psql "postgresql://pgb_admin_user@pgbouncer-admin.cockroachdb.svc.cluster.local:5434/production?sslmode=require&sslcert=/certs/client.crt&sslkey=/certs/client.key&sslrootcert=/certs/ca.crt"

# Or direct to CockroachDB (bypass PgBouncer)
psql "postgresql://pgb_admin_user@cockroachdb-public.cockroachdb.svc.cluster.local:26257/production?sslmode=require&sslcert=/certs/client.crt&sslkey=/certs/client.key&sslrootcert=/certs/ca.crt"
```

### Developer Direct Access (with Okta JWT)

```bash
# CockroachDB native JWT auth (auto-provisions user from JWT)
cockroach sql \
  --url "postgresql://alice@example.com@cockroachdb-public.cockroachdb.svc.cluster.local:26257/production?sslmode=require" \
  --certs-dir=/certs \
  --password  # Paste JWT as password
```

### Flyway (Schema Migrations)

```bash
# Direct connection, bypasses PgBouncer
flyway migrate \
  -url="jdbc:postgresql://cockroachdb-public.cockroachdb.svc.cluster.local:26257/production?sslmode=require" \
  -user=flyway_svc \
  -locations=filesystem:/flyway/sql/production
```

## Observability

### Monitoring Queries

```sql
-- Active connections per pool (run from admin pool)
SELECT 
    application_name,
    COUNT(*) as connection_count,
    COUNT(DISTINCT user_name) as unique_users
FROM crdb_internal.cluster_sessions
GROUP BY application_name;

-- RLS policy evaluation stats
SELECT 
    table_name,
    policy_name,
    count(*) as evaluations
FROM crdb_internal.statement_statistics
WHERE full_scan
  AND table_name IN ('accounts', 'parties')
GROUP BY table_name, policy_name;

-- Pool utilization from PgBouncer
kubectl exec -n cockroachdb deployment/pgbouncer-app -- \
  psql -p 5432 pgbouncer -c 'SHOW POOLS;'
```

### Key Metrics to Monitor

| Metric | Threshold | Action |
|--------|-----------|--------|
| PgBouncer pool saturation | > 90% | Increase pool size percentage |
| RLS policy evaluation time | > 50ms | Add index on role_party_access |
| JWT validation failures | > 1% | Check Okta JWKS availability |
| Flyway migration duration | > 5 min | Review DDL for blocking operations |
| CockroachDB connection count | > 90 | Rebalance pool allocations |

## Disaster Recovery

### RTO/RPO Targets

- **RTO (Recovery Time Objective):** < 4 hours
- **RPO (Recovery Point Objective):** < 1 hour

### Backup Strategy

1. **CockroachDB Backups** (to S3):
   ```sql
   -- Full backup daily
   BACKUP DATABASE production, metadata, staging
   TO 's3://crdb-backups-east/daily?AWS_ACCESS_KEY_ID=...&AWS_SECRET_ACCESS_KEY=...'
   WITH revision_history;
   ```

2. **PgBouncer ConfigMaps** - Version controlled in Git

3. **Vault Secrets** - Backed up to encrypted S3

### Recovery Procedures

**Scenario 1: Single pool failure**
- Kubernetes automatically restarts pod
- Other replicas continue serving traffic
- No manual intervention needed

**Scenario 2: Complete cluster failure**
- Restore from S3 backup
- Redeploy PgBouncer pools
- Reconfigure Istio JWT validation
- RTO: ~2 hours

**Scenario 3: Schema migration rollback**
- Flyway supports rollback via `R__undo_*.sql` scripts
- Manual intervention required for DDL rollback

## Security Considerations

### Principle of Least Privilege

- Service accounts granted only required roles
- RLS enforced on all user-facing queries
- Batch pool bypasses RLS (necessary for ETL)
- Admin pool restricted to DBA group in Okta

### Credential Rotation

**Vault-issued certificates:**
- Rotate every 90 days (automatic via cert-manager)
- PgBouncer pods automatically pick up new certs

**Okta JWT tokens:**
- Short-lived (1 hour TTL)
- Refreshed automatically by application

**Service account passwords:**
- Not used (certificate auth preferred)
- Rotate annually if password auth enabled

### Audit Trail

All access logged via:
1. CockroachDB native audit logging
2. Istio access logs (JWT claims logged)
3. Application middleware logs (session variables)
4. Flyway migration history table

## Performance Characteristics

### Latency Budgets

| Operation | Target | Actual (p95) |
|-----------|--------|--------------|
| App pool query (no RLS) | < 10ms | ~5ms |
| App pool query (with RLS) | < 50ms | ~25ms |
| Batch pool MERGE | < 500ms | ~200ms |
| Flyway migration | < 5 min | ~2 min |
| JWT validation (Istio) | < 5ms | ~2ms |

### Throughput

- **App pool:** 10,000 queries/sec (across 3 replicas)
- **Batch pool:** 500 transactions/sec (MERGE operations)
- **Admin pool:** 100 queries/sec (ad-hoc queries)

## Known Limitations

1. **Transaction pooling limitations:**
   - Session-level variables (SET) cleared between transactions
   - Middleware must inject `SET LOCAL` on every transaction
   - Prepared statements not shared across transactions

2. **RLS performance:**
   - Each query evaluates RLS policy
   - Index on `role_party_access(role_name, party_id)` critical
   - BYPASSRLS roles skip policy evaluation

3. **Flyway direct connection:**
   - DDL bypasses connection pooling
   - Schema migrations can block production traffic
   - Use CockroachDB online DDL features

4. **Istio overhead:**
   - ~2ms added latency for JWT validation
   - Sidecar memory overhead: ~100MB per pod

## Future Enhancements

### Phase 10+: Analytics (PCR West Standby)

Deploy analytics pool pointing to West standby cluster:

```bash
# config.env additions
export PGBOUNCER_ANALYTICS_POOL_PCT="100"  # 100% of West capacity
export PGBOUNCER_ANALYTICS_REPLICAS="3"
export PGBOUNCER_ANALYTICS_PORT="5435"
```

**Analytics pool characteristics:**
- **Pool mode:** Session (Power BI requires long-lived connections)
- **Target:** PCR West standby (read-only)
- **RLS:** Not enforced (analytics schema pre-filtered via views)

### Multi-Region Active-Active

For global deployments, add:
- Regional PgBouncer pools per AWS region
- HAProxy for cross-region load balancing
- REGIONAL BY ROW locality for transactions table

---

## References

- [CockroachDB Multi-Region](https://www.cockroachlabs.com/docs/stable/multiregion-overview.html)
- [PgBouncer Documentation](https://www.pgbouncer.org/config.html)
- [Istio JWT Authentication](https://istio.io/latest/docs/tasks/security/authentication/authn-policy/)
- [sample-data-pipeline](https://github.com/roachlong/sample-data-pipeline)
- [distributed-connection-pooling Terraform](https://github.com/roachlong/distributed-connection-pooling/tree/main/terraform/aws/modules/dcp)
