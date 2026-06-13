# Phase 7: Flyway Schema Migrations

Deploys **Flyway** for automated schema migrations, integrating SQL scripts from the [sample-data-pipeline](https://github.com/roachlong/sample-data-pipeline) repository and adding comprehensive Row-Level Security (RLS) policies.

## What's Deployed

**Flyway Jobs:**
- **flyway-metadata-migration**: Applies migrations to `metadata` database
- **flyway-staging-migration**: Applies migrations to `staging` database
- **flyway-production-migration**: Applies migrations to `production` database (includes RLS)

**Migration Sources:**
1. **Sample Data Pipeline Migrations** (V001-V014):
   - `metadata` database: SOR maps, circuit breakers, batch runs, DQ violations
   - `staging` database: Landing zone tables (stg_workday, stg_hubspot, stg_custodian, stg_core_banking)
   - `production` database: System of Record (parties, accounts, transactions, compliance_events, currencies)

2. **Custom RLS Migrations** (V002, V015-V016):
   - `V002__add_role_party_access.sql`: Creates `role_party_access` table (maps roles to party_ids)
   - `V015__enable_rls_accounts.sql`: Enables RLS on `accounts` table with comprehensive policies
   - `V016__enable_rls_parties.sql`: Enables RLS on `parties` table with comprehensive policies

**Connection Method:**
- Flyway connects **directly to CockroachDB:26257** (bypasses PgBouncer)
- Authenticates with `flyway_svc` client certificate
- Uses `flyway_svc` SQL user (grants `admin` role with BYPASSRLS)

**Why bypass PgBouncer?**
- Flyway executes multiple DDL statements across transactions
- Transaction pooling releases connections between statements
- DDL requires consistent connection for schema lock maintenance
- Direct connection ensures migrations complete atomically

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Flyway Kubernetes Job                                               │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  flyway-metadata-migration                                   │    │
│  │  - Connects to: ${CRDB_HOST}:26257                           │    │
│  │  - Database: metadata                                        │    │
│  │  - Auth: flyway_svc client certificate                       │    │
│  │  - Migrations: V001-V014 from sample-data-pipeline           │    │
│  └─────────────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  flyway-staging-migration                                    │    │
│  │  - Connects to: ${CRDB_HOST}:26257                           │    │
│  │  - Database: staging                                         │    │
│  │  - Auth: flyway_svc client certificate                       │    │
│  │  - Migrations: V001-V014 from sample-data-pipeline           │    │
│  └─────────────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  flyway-production-migration                                 │    │
│  │  - Connects to: ${CRDB_HOST}:26257                           │    │
│  │  - Database: production                                      │    │
│  │  - Auth: flyway_svc client certificate                       │    │
│  │  - Migrations: V001-V014 (sample-data-pipeline)              │    │
│  │                + V002 (role_party_access table)              │    │
│  │                + V015 (RLS on accounts)                      │    │
│  │                + V016 (RLS on parties)                       │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────┬───────────────────────────────────────────────────┘
                  │
                  │ Direct connection (bypasses PgBouncer)
                  │ Port: 26257
                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Service: ${CRDB_CLUSTER_NAME_EAST}-public                           │
│  Port: 26257 (SQL)                                                   │
└─────────────────┬───────────────────────────────────────────────────┘
                  │
                  │ DDL execution with schema locks
                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  CockroachDB Cluster (3 nodes)                                       │
│  - metadata database: Governance schema                              │
│  - staging database: Landing zone schema                             │
│  - production database: SOR schema + RLS policies                    │
└─────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- **Phase 0 complete**: Okta OIDC application configured
- **Phase 1 complete**: EKS cluster deployed
- **Phase 2 complete**: Vault PKI operational
- **Phase 3 complete**: CockroachDB Operator installed
- **Phase 4 complete**: CockroachDB cluster with databases and `flyway_svc` user
- **Phase 5 complete**: Three PgBouncer pools deployed
- **Phase 6 complete**: Istio service mesh deployed
- **sample-data-pipeline cloned**: SQL migration scripts available locally

## Deployment

### Step 1: Clone sample-data-pipeline Repository

```bash
cd /tmp
git clone https://github.com/roachlong/sample-data-pipeline.git
cd sample-data-pipeline

# Verify migration scripts exist
ls -la flyway/sql/metadata/
ls -la flyway/sql/staging/
ls -la flyway/sql/production/
```

### Step 2: Copy Migration Scripts

```bash
cd /path/to/distributed-connection-pooling/kubernetes/eks/manifests/phase7-flyway

# Create SQL directories if they don't exist
mkdir -p sql/metadata sql/staging sql/production

# Copy migration scripts from sample-data-pipeline
cp /tmp/sample-data-pipeline/flyway/sql/metadata/*.sql sql/metadata/ || echo "No metadata migrations"
cp /tmp/sample-data-pipeline/flyway/sql/staging/*.sql sql/staging/ || echo "No staging migrations"
cp /tmp/sample-data-pipeline/flyway/sql/production/*.sql sql/production/

# Verify scripts were copied
ls -la sql/production/
```

### Step 3: Run Setup Script

```bash
chmod +x setup.sh
./setup.sh
```

The script will:

1. **Generate Custom RLS Migration Scripts**:
   
   **V002__add_role_party_access.sql** (production database):
   ```sql
   CREATE TABLE role_party_access (
       role_name STRING NOT NULL,
       party_id UUID NOT NULL,
       access_level STRING NOT NULL CHECK (access_level IN ('read_only', 'read_write')),
       created_at TIMESTAMPTZ DEFAULT now(),
       updated_at TIMESTAMPTZ DEFAULT now(),
       PRIMARY KEY (role_name, party_id)
   );
   
   CREATE INDEX idx_role_party_access_role ON role_party_access (role_name);
   CREATE INDEX idx_role_party_access_party ON role_party_access (party_id);
   
   -- Grant access to app role
   GRANT SELECT ON role_party_access TO app;
   ```

   **V015__enable_rls_accounts.sql** (production database):
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
   ```

   **V016__enable_rls_parties.sql** (production database):
   ```sql
   -- Enable RLS on parties table
   ALTER TABLE parties ENABLE ROW LEVEL SECURITY;
   ALTER TABLE parties FORCE ROW LEVEL SECURITY;
   
   -- Policy: Users can only access parties their roles grant access to
   CREATE POLICY role_based_party_access ON parties
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
   ```

2. **Create ConfigMaps** with SQL scripts:
   - `flyway-metadata-scripts` (from sql/metadata/*.sql)
   - `flyway-staging-scripts` (from sql/staging/*.sql)
   - `flyway-production-scripts` (from sql/production/*.sql + RLS scripts)

3. **Create Flyway Kubernetes Jobs**:
   - `flyway-metadata-migration` (runs once, creates metadata schema)
   - `flyway-staging-migration` (runs once, creates staging schema)
   - `flyway-production-migration` (runs once, creates production schema + RLS)

4. **Wait for Jobs to Complete**:
   - Metadata migrations complete
   - Staging migrations complete
   - Production migrations complete (including RLS)

5. **Verify Migrations**:
   - Check `flyway_schema_history` table in each database
   - Verify RLS is enabled on accounts and parties tables
   - Display migration summary

## Validation

### Check Flyway Job Status

```bash
# Check all Flyway jobs
kubectl get jobs -n cockroachdb | grep flyway

# Expected output:
# NAME                          COMPLETIONS   DURATION   AGE
# flyway-metadata-migration     1/1           45s        3m
# flyway-staging-migration      1/1           52s        3m
# flyway-production-migration   1/1           67s        3m

# Check job pods
kubectl get pods -n cockroachdb | grep flyway

# Expected: Completed status for all
```

### Check Migration History

**Metadata Database:**

```bash
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=metadata \
    --execute="SELECT installed_rank, version, description, type, script, success, installed_on FROM flyway_schema_history ORDER BY installed_rank;"
```

**Staging Database:**

```bash
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=staging \
    --execute="SELECT installed_rank, version, description, success FROM flyway_schema_history ORDER BY installed_rank;"
```

**Production Database:**

```bash
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production \
    --execute="SELECT installed_rank, version, description, success FROM flyway_schema_history ORDER BY installed_rank;"
```

Expected versions in production:
- V001: Create currencies table
- V002: Add role_party_access table (custom)
- V003: Create parties table
- V004: Create accounts table
- ...
- V014: Final sample-data-pipeline migration
- V015: Enable RLS on accounts (custom)
- V016: Enable RLS on parties (custom)

### Verify Tables Exist

**Production Database Tables:**

```bash
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production \
    --execute="SHOW TABLES;"
```

Expected tables:
- `accounts`
- `compliance_events`
- `currencies`
- `flyway_schema_history`
- `parties`
- `role_party_access`
- `transactions`

### Verify RLS is Enabled

```bash
# Check RLS status on accounts and parties
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production \
    --execute="SELECT tablename, rowsecurity FROM pg_tables WHERE schemaname = 'public' AND tablename IN ('accounts', 'parties');"

# Expected:
#   tablename  | rowsecurity
# -------------+-------------
#   accounts   | t
#   parties    | t
```

### Verify RLS Policies

```bash
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production \
    --execute="SELECT tablename, policyname, cmd, qual FROM pg_policies WHERE tablename IN ('accounts', 'parties');"

# Expected:
#   tablename |        policyname        | cmd |                    qual
# ------------+--------------------------+-----+--------------------------------------------
#   accounts  | role_based_account_access| ALL | current_setting('app.current_user'...
#   parties   | role_based_party_access  | ALL | current_setting('app.current_user'...
```

### Test RLS Filtering

**Insert Test Data:**

```bash
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -it -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs --database=production

-- In SQL shell:
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

-- Grant role-based party access
INSERT INTO role_party_access (role_name, party_id, access_level) VALUES
('crdb_advisor_team_east', '11111111-1111-1111-1111-111111111111', 'read_write'),
('crdb_advisor_team_east', '33333333-3333-3333-3333-333333333333', 'read_write'),
('crdb_advisor_team_west', '22222222-2222-2222-2222-222222222222', 'read_write'),
('crdb_client_services', '11111111-1111-1111-1111-111111111111', 'read_only'),
('crdb_client_services', '22222222-2222-2222-2222-222222222222', 'read_only'),
('crdb_client_services', '33333333-3333-3333-3333-333333333333', 'read_only');
```

**Test RLS Filtering:**

```bash
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs --database=production <<'EOF'
-- Test as crdb_advisor_team_east (should see ACCT-EAST-001 and ACCT-EAST-002)
BEGIN;
SET LOCAL app.current_user = 'advisor.east@example.com';
SET LOCAL app.current_roles = 'crdb_advisor_team_east';
SELECT account_number, party_id, balance FROM accounts ORDER BY account_number;
COMMIT;
EOF

# Expected output:
#   account_number |               party_id               | balance
# -----------------+--------------------------------------+----------
#   ACCT-EAST-001  | 11111111-1111-1111-1111-111111111111 | 10000.00
#   ACCT-EAST-002  | 33333333-3333-3333-3333-333333333333 | 50000.00
```

```bash
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs --database=production <<'EOF'
-- Test as crdb_advisor_team_west (should only see ACCT-WEST-001)
BEGIN;
SET LOCAL app.current_user = 'advisor.west@example.com';
SET LOCAL app.current_roles = 'crdb_advisor_team_west';
SELECT account_number, party_id, balance FROM accounts ORDER BY account_number;
COMMIT;
EOF

# Expected output:
#   account_number |               party_id               | balance
# -----------------+--------------------------------------+----------
#   ACCT-WEST-001  | 22222222-2222-2222-2222-222222222222 | 20000.00
```

```bash
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs --database=production <<'EOF'
-- Test without session variables (should see no rows)
SELECT account_number FROM accounts;
EOF

# Expected: 0 rows (RLS blocks access without app.current_user and app.current_roles)
```

## Migration Scripts from sample-data-pipeline

### Metadata Database (V001-V014)

**Purpose**: Governance data for ETL orchestration

**Key Tables**:
- `sor_maps`: Source-of-record mapping configuration
- `circuit_breakers`: Circuit breaker rules for data quality
- `batch_runs`: ETL batch execution history
- `dq_violations`: Data quality violation records

**Example Migration (V001__create_sor_maps.sql)**:
```sql
CREATE TABLE sor_maps (
    sor_map_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_type STRING NOT NULL,
    source_system STRING NOT NULL,
    priority INT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);
```

### Staging Database (V001-V014)

**Purpose**: Landing zone for raw source system data

**Key Tables**:
- `stg_workday`: Staging table for Workday HR data
- `stg_hubspot`: Staging table for HubSpot CRM data
- `stg_custodian`: Staging table for custodian financial data
- `stg_core_banking`: Staging table for core banking data

**Example Migration (V002__create_stg_workday.sql)**:
```sql
CREATE TABLE stg_workday (
    staging_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_record_id STRING NOT NULL,
    employee_id STRING,
    full_name STRING,
    email STRING,
    department STRING,
    load_timestamp TIMESTAMPTZ DEFAULT now()
);
```

### Production Database (V001-V014 + Custom RLS)

**Purpose**: System of Record (golden records)

**Core Tables from sample-data-pipeline**:

1. **currencies** (V001):
   ```sql
   CREATE TABLE currencies (
       currency_code STRING PRIMARY KEY,
       currency_name STRING NOT NULL,
       symbol STRING
   );
   ```

2. **parties** (V003):
   ```sql
   CREATE TABLE parties (
       party_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
       party_name STRING NOT NULL,
       party_type STRING NOT NULL,
       region STRING,
       source_system STRING NOT NULL,
       source_record_id STRING NOT NULL,
       created_at TIMESTAMPTZ DEFAULT now(),
       updated_at TIMESTAMPTZ DEFAULT now()
   );
   ```

3. **accounts** (V004):
   ```sql
   CREATE TABLE accounts (
       account_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
       party_id UUID NOT NULL REFERENCES parties(party_id),
       account_number STRING NOT NULL,
       account_type STRING NOT NULL,
       account_status STRING NOT NULL,
       balance DECIMAL(18,2),
       currency_code STRING NOT NULL REFERENCES currencies(currency_code),
       source_system STRING NOT NULL,
       source_record_id STRING NOT NULL,
       load_timestamp TIMESTAMPTZ DEFAULT now(),
       created_at TIMESTAMPTZ DEFAULT now(),
       updated_at TIMESTAMPTZ DEFAULT now()
   );
   
   CREATE INDEX idx_accounts_party ON accounts (party_id);
   ```

4. **transactions** (V005):
   ```sql
   CREATE TABLE transactions (
       transaction_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
       account_id UUID NOT NULL REFERENCES accounts(account_id),
       transaction_date TIMESTAMPTZ NOT NULL,
       amount DECIMAL(18,2) NOT NULL,
       transaction_type STRING NOT NULL,
       description STRING,
       created_at TIMESTAMPTZ DEFAULT now()
   );
   
   CREATE INDEX idx_transactions_account ON transactions (account_id);
   ```

5. **compliance_events** (V006):
   ```sql
   CREATE TABLE compliance_events (
       event_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
       party_id UUID NOT NULL REFERENCES parties(party_id),
       event_type STRING NOT NULL,
       event_date TIMESTAMPTZ NOT NULL,
       severity STRING NOT NULL,
       description TEXT,
       created_at TIMESTAMPTZ DEFAULT now()
   );
   
   CREATE INDEX idx_compliance_party ON compliance_events (party_id);
   ```

**Custom RLS Tables and Policies**:

6. **role_party_access** (V002 - custom):
   - Maps CockroachDB roles to party_ids
   - Access levels: read_only, read_write
   - Critical for RLS policy evaluation

7. **RLS policies** (V015-V016 - custom):
   - `accounts` table: Filters by `app.current_roles` session variable
   - `parties` table: Filters by `app.current_roles` session variable
   - Cascading: Joined tables (transactions, compliance_events) automatically filtered

## RLS Policy Details

### Policy Logic

**USING Clause** (SELECT, UPDATE, DELETE):
```sql
current_setting('app.current_user', true) != ''
AND current_setting('app.current_roles', true) != ''
AND party_id IN (
  SELECT party_id FROM role_party_access
  WHERE role_name = ANY(string_to_array(current_setting('app.current_roles', true), ','))
)
```

**Explanation**:
1. Require `app.current_user` is set (not empty)
2. Require `app.current_roles` is set (not empty)
3. Filter rows where `party_id` exists in `role_party_access` for ANY of the user's roles

**WITH CHECK Clause** (INSERT, UPDATE):
```sql
current_setting('app.current_user', true) != ''
AND current_setting('app.current_roles', true) != ''
AND party_id IN (
  SELECT party_id FROM role_party_access
  WHERE role_name = ANY(string_to_array(current_setting('app.current_roles', true), ','))
    AND access_level = 'read_write'
)
```

**Explanation**:
1. Same requirements as USING clause
2. **Additionally** require `access_level = 'read_write'` in `role_party_access`
3. Prevents read-only roles from inserting/updating rows

### RLS Cascading

RLS on `accounts` and `parties` tables automatically filters joined tables:

```sql
-- Query transactions (no RLS on transactions table)
SELECT t.* 
FROM transactions t
JOIN accounts a ON t.account_id = a.account_id;

-- Result: Only transactions for accounts the user can access
-- RLS on accounts filters joined rows automatically
```

**Why this works**:
- `transactions` table has FK to `accounts.account_id`
- Join requires matching `account_id`
- RLS on `accounts` filters visible rows
- Only matching transactions are visible in result

**No explicit RLS needed on**:
- `transactions` (filtered via FK to accounts)
- `compliance_events` (filtered via FK to parties)

### Bypassing RLS

Users with `BYPASSRLS` privilege skip all RLS policies:
- `admin` role (for DBAs, Flyway, batch jobs)
- `flyway_svc` user (schema migrations)
- `pgb_batch_user` (batch pool ETL operations)
- `pgb_admin_user` (admin pool operations)

**Batch operations** (via pgbouncer-batch:5433) see all rows:
```bash
# ETL script connecting to batch pool
psql "host=pgbouncer-batch port=5433 dbname=staging" \
    -c "INSERT INTO staging.stg_workday SELECT * FROM source;"

# No RLS filtering - pgb_batch_user has BYPASSRLS
```

## Flyway Configuration

### Connection String

Flyway uses direct connection to CockroachDB (not through PgBouncer):

```
jdbc:postgresql://${CRDB_CLUSTER_NAME_EAST}-public.cockroachdb.svc.cluster.local:26257/<database>?sslmode=verify-full&sslcert=/certs/client.flyway_svc.crt&sslkey=/certs/client.flyway_svc.key&sslrootcert=/certs/ca.crt
```

**Key Parameters**:
- `sslmode=verify-full`: Verify server certificate
- `sslcert`, `sslkey`: Client certificate for `flyway_svc` user
- Database: metadata, staging, or production

### Flyway Options

```properties
flyway.locations=filesystem:/flyway/sql
flyway.baselineOnMigrate=true
flyway.validateOnMigrate=true
flyway.cleanDisabled=true
flyway.table=flyway_schema_history
```

**Important**:
- `cleanDisabled=true`: Prevents accidental schema wipe
- `baselineOnMigrate=true`: Allows migrations on existing databases
- Scripts must follow naming: `V<version>__<description>.sql`

## Re-Running Migrations

**Adding New Migrations:**

1. Add new SQL file with higher version number:
   ```bash
   cd sql/production
   vi V017__add_new_table.sql
   ```

2. Update ConfigMap:
   ```bash
   cd ../..
   kubectl delete configmap flyway-production-scripts -n cockroachdb
   kubectl create configmap flyway-production-scripts \
       --from-file=sql/production/ \
       -n cockroachdb
   ```

3. Delete and re-run Flyway job:
   ```bash
   kubectl delete job flyway-production-migration -n cockroachdb
   ./setup.sh  # Will create new job
   ```

**Flyway Versioning**:
- Flyway tracks applied migrations in `flyway_schema_history`
- Only new migrations (higher version numbers) are executed
- Already-applied migrations are skipped
- Checksums verify script integrity (changes to applied scripts cause errors)

## Troubleshooting

### Migration Job Failures

**Check Job Logs:**

```bash
kubectl logs -n cockroachdb job/flyway-production-migration
```

Common errors:
- **SQL syntax error**: Fix SQL script, delete job, re-run
- **Connection timeout**: Verify CockroachDB service is reachable
- **Authentication failure**: Verify flyway_svc client certificate exists
- **Migration checksum mismatch**: SQL script was modified after being applied

### SQL Syntax Errors

```bash
# Test SQL script manually before Flyway
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --database=production < sql/production/V015__enable_rls_accounts.sql
```

### RLS Policy Errors

**Problem**: Policy syntax error during V015 or V016

```bash
# Check CockroachDB version supports RLS
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach version

# Expected: v25.4.11 or later (RLS added in v22.1)

# Test policy manually
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -it -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs --database=production

-- In SQL shell:
-- Test current_setting function
SELECT current_setting('app.current_roles', true);

-- Verify role_party_access table exists
\d role_party_access
```

### Missing Tables from sample-data-pipeline

**Problem**: V004 references V003 table (dependencies)

```bash
# Verify migration order
ls -la sql/production/ | grep ^V

# Ensure V001-V014 are in order
# V001 should create currencies
# V003 should create parties (referenced by V004 accounts)
# V004 should create accounts (FK to parties)
```

### ConfigMap Too Large

**Problem**: ConfigMap exceeds 1MB limit (many large SQL scripts)

```bash
# Check ConfigMap size
kubectl get configmap flyway-production-scripts -n cockroachdb -o yaml | wc -c

# Solution: Split into multiple ConfigMaps or use init container to fetch from Git
```

## Teardown

```bash
cd ../..
./teardown.sh --phase 7
```

This will remove:
- Three Flyway Jobs (metadata, staging, production)
- Three ConfigMaps with SQL scripts
- **Does NOT** drop tables or remove data (data persists in CockroachDB)
- **Does NOT** remove `flyway_schema_history` tables

**To completely reset schema** (WARNING: destroys data):
```bash
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="DROP DATABASE production CASCADE;"
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql --certs-dir=/cockroach/cockroach-certs \
    --execute="CREATE DATABASE production;"

# Re-run Flyway
cd manifests/phase7-flyway
./setup.sh
```

## Next Steps

### Phase 8: Apache NiFi Data Flow Platform

Deploy NiFi 2.x as the ETL and data flow orchestration layer:
- 3-node NiFi cluster + NiFi Registry on dedicated EKS node group
- ZooKeeper (3 nodes) and Kafka (3 brokers) as separate StatefulSets
- JDBC connectivity to CockroachDB via PgBouncer batch pool (port 5433)
- Git-backed flow versioning via NiFi Registry
- Full mTLS with cert-manager certificates, Istio passthrough

The NiFi flows consume the schema and data produced by Flyway migrations and the sample-data-pipeline ETL, orchestrating data movement between staging and production databases.

See [manifests/phase8-nifi/README.md](../phase8-nifi/README.md)

### Phase 9: Enterprise Features

Enable Enterprise license and features:
- S3 backups with IRSA (automated full + incremental)
- Encryption-at-rest with customer-managed keys
- Changefeeds for NiFi flows (real-time CockroachDB → NiFi data streaming)

See [manifests/phase9-enterprise/README.md](../phase9-enterprise/README.md)

### Deploy sample-data-pipeline ETL

Run Python ETL scripts against deployed schema:

```bash
cd /tmp/sample-data-pipeline

# Configure connection to batch pool (BYPASSRLS)
export CRDB_HOST="pgbouncer-batch.cockroachdb.svc.cluster.local"
export CRDB_PORT="5433"
export CRDB_USER="root"
export CRDB_DATABASE="staging"

# Run ETL pipeline
python scripts/load_staging.py
python scripts/merge_to_production.py
python scripts/evaluate_circuit_breakers.py
```

### Application Integration

Update applications to use RLS-enforced app pool:

```python
# Example Flask middleware
from flask import g, request
import jwt
import psycopg

def before_request():
    # Extract JWT from Authorization header
    auth_header = request.headers.get('Authorization', '')
    if not auth_header.startswith('Bearer '):
        abort(401)
    
    token = auth_header[7:]
    claims = jwt.decode(token, options={"verify_signature": False})
    
    g.user_email = claims['sub']
    g.user_roles = ','.join([
        role.replace('example-crdb-', '')
        for role in claims['groups']
        if role.startswith('example-crdb-')
    ])

def execute_query(query, params):
    conn = psycopg.connect(
        "host=pgbouncer-app port=5432 dbname=production",
        sslmode='require'
    )
    conn.autocommit = False
    
    try:
        cursor = conn.cursor()
        cursor.execute("BEGIN;")
        cursor.execute("SET LOCAL app.current_user = %s;", (g.user_email,))
        cursor.execute("SET LOCAL app.current_roles = %s;", (g.user_roles,))
        cursor.execute(query, params)
        result = cursor.fetchall()
        conn.commit()
        return result
    except Exception as e:
        conn.rollback()
        raise
    finally:
        conn.close()
```

## References

**Flyway Documentation:**
- [Flyway Command-line](https://flywaydb.org/documentation/usage/commandline/)
- [Flyway SQL-based Migrations](https://flywaydb.org/documentation/concepts/migrations#sql-based-migrations)
- [Versioned Migrations](https://flywaydb.org/documentation/concepts/migrations#versioned-migrations)

**CockroachDB Documentation:**
- [Row-Level Security](https://www.cockroachlabs.com/docs/stable/row-level-security)
- [CREATE POLICY](https://www.cockroachlabs.com/docs/stable/create-policy)
- [Session Variables](https://www.cockroachlabs.com/docs/stable/set-vars)

**Architecture Documentation:**
- [ARCHITECTURE.md](../../ARCHITECTURE.md) - Complete system architecture
- [CockroachDB Connectivity Guide](../../generated/references/0.4%20CockroachDB%20Connectivity%20Guide_%20User%20Access%20Design.pdf) - RLS design pattern
- [Data Access Control](../../generated/references/3.1%20Data%20Access%20Control%20—%20RBAC,%20RLS,%20Column%20Security,%20and%20Okta%20SSO.pdf) - Security layers

**Sample Data Pipeline:**
- [sample-data-pipeline](https://github.com/roachlong/sample-data-pipeline) - ETL pipeline and migration scripts
