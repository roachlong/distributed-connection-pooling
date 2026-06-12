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

### Three-Tier Role Architecture

The security model uses three distinct types of roles that work together to enforce both **RBAC** (what operations you can perform) and **RLS** (which data you can see):

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Service Accounts          Parent Roles           Okta-Mapped Roles     │
│  (LOGIN, cert auth)        (NOLOGIN, templates)   (NOLOGIN, RLS IDs)    │
├─────────────────────────────────────────────────────────────────────────┤
│  pgb_app_user    ─┐                                                     │
│                   ├─→ app ────────┬→ crdb_advisor_team_east             │
│  pgb_batch_user  ─┼─→ admin ──────┼→ crdb_advisor_team_west             │
│  pgb_admin_user  ─┘   │           ├→ crdb_client_services               │
│  flyway_svc      ─────┘           ├→ crdb_compliance_team               │
│                                    ├→ crdb_fiduciary_admin               │
│                       readonly ────┼→ crdb_batch_service                 │
│                       pipeline     ├→ crdb_developers                    │
│                       powerbi      │                                     │
│                       compliance   │                                     │
│                       developer    │                                     │
└─────────────────────────────────────────────────────────────────────────┘

Purpose:                 Purpose:               Purpose:
• PgBouncer connects     • Define allowed       • RLS policy filtering
• Certificate auth       • Permission templates • Auto-provisioned
• RBAC ceiling           • Grant to service     • Maps Okta groups
• WITH LOGIN             • accounts             • NOLOGIN
```

#### 1. Service Accounts (LOGIN - Certificate Auth)

These are the **only** users that can actually login to CockroachDB:

```sql
CREATE USER pgb_app_user WITH LOGIN;      -- App pool backend
CREATE USER pgb_batch_user WITH LOGIN;    -- Batch pool backend
CREATE USER pgb_admin_user WITH LOGIN;    -- Admin pool backend
CREATE USER flyway_svc WITH LOGIN;        -- Schema migrations
```

**Authentication:** Certificate-only (no password)
- Certificates issued by Vault PKI via cert-manager
- PgBouncer uses these certificates to authenticate to CockroachDB
- Each PgBouncer pool authenticates as its service account

**RBAC Ceiling:** Service account permissions are the **hard limit**:
```sql
-- App pool can only do what app role allows
GRANT app TO pgb_app_user;

-- Batch/admin pools have elevated permissions
GRANT admin TO pgb_batch_user WITH ADMIN OPTION;
GRANT admin TO pgb_admin_user WITH ADMIN OPTION;
GRANT admin TO flyway_svc WITH ADMIN OPTION;
```

#### 2. Parent Roles (NOLOGIN - Permission Templates)

These define **what operations** are allowed, not **who** can login:

```sql
CREATE ROLE readonly NOLOGIN;      -- Read-only access
CREATE ROLE app NOLOGIN;           -- Application data access (SELECT, INSERT, UPDATE, DELETE)
CREATE ROLE pipeline NOLOGIN;      -- ETL/staging access
CREATE ROLE powerbi NOLOGIN;       -- Analytics/reporting
CREATE ROLE compliance NOLOGIN;    -- Compliance views
CREATE ROLE developer NOLOGIN;     -- Development environment
CREATE ROLE admin NOLOGIN;         -- Full cluster access, DDL, BYPASSRLS

-- Inheritance hierarchy
GRANT readonly TO app;  -- app inherits readonly permissions
```

**Permissions Example:**
```sql
-- Grant database-level permissions to parent roles
GRANT ALL ON DATABASE production TO app;
GRANT CONNECT ON DATABASE production TO readonly;

-- Grant schema-level permissions
USE production;
GRANT USAGE ON SCHEMA public TO app;
GRANT USAGE ON SCHEMA public TO readonly;

-- Table permissions granted after Flyway creates tables (Phase 7)
GRANT SELECT, INSERT, UPDATE, DELETE ON accounts TO app;
GRANT SELECT ON accounts TO readonly;
```

#### 3. Okta-Mapped Roles (NOLOGIN - RLS Identities)

These define **which data** users can see via RLS policies:

```sql
-- Created by Phase 4 setup (static)
CREATE ROLE crdb_advisor_team_east NOLOGIN;
CREATE ROLE crdb_advisor_team_west NOLOGIN;
CREATE ROLE crdb_client_services NOLOGIN;
CREATE ROLE crdb_compliance_team NOLOGIN;
CREATE ROLE crdb_fiduciary_admin NOLOGIN;
CREATE ROLE crdb_batch_service NOLOGIN;
CREATE ROLE crdb_developers NOLOGIN;

-- Grant parent role permissions
GRANT app TO crdb_advisor_team_east;
GRANT app TO crdb_advisor_team_west;
GRANT readonly TO crdb_client_services;
GRANT compliance TO crdb_compliance_team;
GRANT app TO crdb_fiduciary_admin;
GRANT admin TO crdb_batch_service;
GRANT developer TO crdb_developers;
```

**Auto-Provisioning:** When a user logs in via JWT, CockroachDB:
1. Creates a user with their email address (e.g., `alice@example.com`)
2. Grants them roles based on JWT `groups` claim
3. Uses identity mapping: `example-issuer /^(.*)@.*$ \1` to strip domain

**RLS Filtering:** Policies read session variables set by application middleware:
```sql
CREATE POLICY advisor_east_access ON accounts
  FOR ALL
  TO app  -- Anyone with app role
  USING (
    current_setting('app.current_roles') = 'crdb_advisor_team_east'
    AND region = 'east'
  );
```

### RBAC Security Boundaries

**Critical Security Principle:** You **cannot** escalate beyond the service account's granted roles.

**What Happens:**
```sql
-- Connect through app pool → authenticated as pgb_app_user
-- pgb_app_user has been granted: app role

-- This FAILS (admin was never granted to pgb_app_user)
SET ROLE admin;
-- ERROR: permission denied to set role "admin"

-- This works (app was granted to pgb_app_user)
SET ROLE app;  -- Changes nothing, already the effective role

-- Session variables are for RLS filtering, NOT authorization
SET LOCAL app.current_user = 'alice@example.com';  -- RLS identity
SET LOCAL app.current_roles = 'crdb_advisor_team_east';  -- RLS filtering
```

**RBAC is bounded by:**
1. **Service account grants** - `pgb_app_user` only has `app` role
2. **Parent role permissions** - `app` role only has SELECT/INSERT/UPDATE/DELETE
3. **Database grants** - Even `app` role can only access granted databases/tables

**Example - What Each Pool Can Do:**

| Operation | App Pool (`app` role) | Batch Pool (`admin` role) | Admin Pool (`admin` role) |
|-----------|----------------------|---------------------------|---------------------------|
| SELECT from accounts | ✅ Yes (with RLS) | ✅ Yes (BYPASSRLS) | ✅ Yes (BYPASSRLS) |
| INSERT into accounts | ✅ Yes (with RLS) | ✅ Yes (BYPASSRLS) | ✅ Yes (BYPASSRLS) |
| CREATE TABLE | ❌ No (requires admin) | ✅ Yes | ✅ Yes |
| GRANT privileges | ❌ No (requires admin) | ✅ Yes | ✅ Yes |
| ALTER USER | ❌ No (requires admin) | ✅ Yes | ✅ Yes |
| BACKUP | ❌ No (requires admin) | ✅ Yes | ✅ Yes |
| SET ROLE admin | ❌ ERROR | ✅ Already admin | ✅ Already admin |

### Multi-Layer Defense in Depth

Security is enforced at **four independent layers** - even if one layer fails, others prevent compromise:

#### Layer 1: Network Isolation (Istio Service Mesh - Phase 6)

**Enforcement:** Applications **never** connect directly to PgBouncer.

```
Application → Istio Sidecar → PgBouncer → CockroachDB
```

**Istio Sidecar:**
1. **Validates JWT** signature against Okta JWKS (cryptographic proof)
2. **Rejects unsigned/expired JWTs** before reaching PgBouncer
3. **Extracts claims** from validated JWT:
   - `email` → `x-user-email` header
   - `groups` → `x-user-groups` header
4. **Application middleware** reads headers and injects session variables

**Network Policies (Kubernetes):**
```yaml
# Only allow traffic to PgBouncer from pods with Istio sidecar
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: pgbouncer-access
spec:
  ingress:
  - from:
    - podSelector:
        matchLabels:
          istio-injection: enabled  # Must have Istio sidecar
```

**Why This Matters:** 
- Applications cannot bypass JWT validation
- Cannot forge session variables (Istio sets them from validated JWT)
- Cannot connect directly to PgBouncer to inject fake identity

#### Layer 2: Service Account Permissions (RBAC Ceiling)

**Enforcement:** Database operations are bounded by service account grants.

```sql
-- App pool: No DDL, no BYPASSRLS, no admin operations
GRANT app TO pgb_app_user;

-- Even if malicious app tries:
ALTER TABLE accounts DROP COLUMN balance;
-- ERROR: permission denied (app role has no DDL privileges)

SET ROLE admin;
-- ERROR: permission denied to set role "admin"
```

**Pool Separation:**
- App pool (port 5432) → `pgb_app_user` → limited permissions
- Batch pool (port 5433) → `pgb_batch_user` → BYPASSRLS for ETL
- Admin pool (port 5434) → `pgb_admin_user` → full access for DBAs

**Network Policies** also enforce pool access:
- App pool: accessible from application pods
- Batch pool: accessible from ETL pods only
- Admin pool: accessible from admin tools only

#### Layer 3: RLS Policies (Data Filtering)

**Enforcement:** Even with valid permissions, RLS filters which **rows** are visible.

```sql
-- RLS policy on accounts table
CREATE POLICY role_based_access ON accounts
  FOR ALL
  TO app  -- Applied to anyone with app role
  USING (
    -- Filter based on session variables
    current_setting('app.current_user', true) != ''
    AND current_setting('app.current_roles', true) != ''
    AND party_id IN (
      SELECT party_id FROM role_party_access
      WHERE role_name = ANY(string_to_array(
        current_setting('app.current_roles', true), ','
      ))
    )
  );
```

**Trust Model:**
- Session variables (`app.current_user`, `app.current_roles`) are set by **application middleware**
- Middleware reads headers injected by **Istio** (Layer 1)
- Istio validates **JWT from Okta** (cryptographic proof)
- Cannot be forged because application cannot reach PgBouncer without Istio

**RLS Bypass:**
- `admin` role has `BYPASSRLS` attribute (batch and admin pools)
- Used for ETL operations that need full table access
- Used for DBA operations and troubleshooting

#### Layer 4: Certificate Authentication

**Enforcement:** Service accounts require certificate authentication (no password).

```sql
-- Service accounts have LOGIN but no password
CREATE USER pgb_app_user WITH LOGIN;  -- No PASSWORD clause

-- Authentication ONLY via certificate
-- Certificate issued by Vault PKI with:
--   CN = pgb_app_user
--   Signed by trusted CA
```

**Certificate Management:**
- Vault PKI issues certificates with 1-year validity
- cert-manager automatically renews before expiration
- Kubernetes mounts certificates as secrets (read-only)
- PgBouncer pods access via `/cockroach-certs/` mount

**Why This Matters:**
- No shared passwords to leak
- Certificates tied to specific service accounts
- Automatic rotation via cert-manager
- Vault provides audit trail of all issued certificates

### Complete Authentication Flow

**User Journey (App Pool):**

```
1. User → Okta Login
   ↓
   Okta validates credentials → issues JWT
   JWT contains: {
     "email": "alice@example.com",
     "groups": ["crdb_advisor_team_east"]
   }

2. User → Application (with JWT in Authorization header)
   ↓
   Application passes JWT to Istio

3. Istio Sidecar
   ↓
   • Validates JWT signature against Okta JWKS
   • Checks expiration
   • Extracts claims → injects headers:
     x-user-email: alice@example.com
     x-user-groups: crdb_advisor_team_east
   ↓
   Forwards to Application

4. Application Middleware
   ↓
   • Reads headers from Istio
   • Wraps database transaction:
   
   BEGIN;
   SET LOCAL app.current_user = 'alice@example.com';
   SET LOCAL app.current_roles = 'crdb_advisor_team_east';
   
   -- Business query
   SELECT * FROM accounts WHERE account_status = 'active';
   -- RLS policy filters: only accounts where party_id IN (
   --   SELECT party_id FROM role_party_access 
   --   WHERE role_name = 'crdb_advisor_team_east'
   -- )
   
   COMMIT;  -- Session variables automatically cleared

5. Application → PgBouncer (app pool, port 5432)
   ↓
   PgBouncer accepts connection (any username, auth_type=any)

6. PgBouncer → CockroachDB
   ↓
   • Authenticates as pgb_app_user (certificate)
   • CockroachDB verifies certificate against CA
   • pgb_app_user has app role
   ↓
   Query executes with:
   - RBAC: app role permissions (SELECT, INSERT, UPDATE, DELETE)
   - RLS: Filtered by session variables
   ↓
   Returns only accounts for crdb_advisor_team_east parties

7. Results → Application → User
```

### Trust Model Summary

**You ARE Trusting:**
- **Okta** - to authenticate users and sign JWTs correctly
- **Istio** - to validate JWTs and inject correct headers
- **Application middleware** - to set session variables from headers (it's your code in your cluster)
- **Network policies** - to prevent direct PgBouncer access
- **CockroachDB RBAC** - to enforce service account permission boundaries

**You are NOT Trusting:**
- **End users** - to provide correct identity (JWT cryptographically verified)
- **Applications** - to bypass Istio (network enforced)
- **Service accounts** - to escalate privileges (RBAC enforced by CockroachDB)
- **Session variables** - without validation chain (Istio → JWT → Okta)

**Defense in Depth:** Each layer independently enforces security:
- **Network down?** → RBAC still limits operations
- **Istio bypassed?** → Still bounded by service account permissions (can't get admin)
- **RLS policy bug?** → Still can't perform DDL or access other databases
- **Certificate leaked?** → Still bounded by that service account's grants

This is similar to how OAuth/OIDC works in modern architectures - your application tier is **trusted code** that mediates between untrusted users and backend systems, with cryptographic proof (JWT) and network enforcement (Istio + NetworkPolicies) ensuring the trust chain cannot be broken.

### Security Validation Checklist

**Phase 4 (Infrastructure):**
- ✅ Service accounts created with LOGIN (certificate auth only)
- ✅ Parent roles created with NOLOGIN (permission templates)
- ✅ Okta-mapped roles created with NOLOGIN (RLS identities)
- ✅ Certificates issued for all service accounts

**Phase 5 (PgBouncer):**
- ✅ Three pools with separate service accounts
- ✅ auth_type=any (accepts any client username, authenticates backend as service account)
- ✅ Certificate authentication to CockroachDB
- ✅ Client and server TLS enabled

**Phase 6 (Istio):**
- ✅ RequestAuthentication validates JWT
- ✅ Headers injected: x-user-email, x-user-groups
- ✅ NetworkPolicies enforce Istio requirement

**Phase 7 (Schema + RLS):**
- ✅ RLS policies created on accounts and parties tables
- ✅ Policies read current_setting('app.current_user') and current_setting('app.current_roles')
- ✅ role_party_access table populated

**Testing RBAC Boundaries:**
```bash
# Test that app pool cannot escalate
psql "postgresql://test@pgbouncer-app:5432/production?sslmode=require" <<EOF
SET ROLE admin;  -- Should FAIL
CREATE TABLE test (id INT);  -- Should FAIL (no DDL)
SELECT * FROM accounts;  -- Should work (with RLS)
EOF

# Test that batch pool bypasses RLS
psql "postgresql://test@pgbouncer-batch:5433/production?sslmode=require" <<EOF
SELECT COUNT(*) FROM accounts;  -- Should see ALL rows (BYPASSRLS)
EOF
```

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
| production | System of record | accounts, transactions, parties, compliance_events, currencies, regulatory_codes | REGIONAL BY ROW (accounts, parties); REGIONAL BY TABLE (others) | All pools |

### Key Production Tables

**accounts** (REGIONAL BY ROW):
```sql
CREATE TABLE accounts (
    crdb_region crdb_internal_region NOT NULL DEFAULT gateway_region()::crdb_internal_region,
    account_id UUID DEFAULT gen_random_uuid(),
    party_id UUID NOT NULL,  -- References parties(party_id) with same crdb_region
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
    updated_at TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (crdb_region, account_id)
);

ALTER TABLE accounts SET LOCALITY REGIONAL BY ROW;
ALTER TABLE accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE accounts FORCE ROW LEVEL SECURITY;
```

**parties** (REGIONAL BY ROW):
```sql
CREATE TABLE parties (
    crdb_region crdb_internal_region NOT NULL DEFAULT gateway_region()::crdb_internal_region,
    party_id UUID DEFAULT gen_random_uuid(),
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
    updated_at TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (crdb_region, party_id)
);

ALTER TABLE parties SET LOCALITY REGIONAL BY ROW;
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
