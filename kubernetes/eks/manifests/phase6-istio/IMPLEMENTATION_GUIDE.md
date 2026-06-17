# Phase 6: Istio Service Mesh - Implementation Guide

## Objective

Deploy Istio service mesh to support **Use Case 1: End User via Application (RLS Enforced)** from the CockroachDB Connectivity Guide.

Istio validates JWT tokens from Okta/WSOC OIDC, extracts user identity claims, and injects them as request headers for application middleware to consume. This enables seamless RLS enforcement without requiring application teams to implement JWT validation logic.

## Architecture Decision

### What Istio Does (Phase 6)

```
┌─────────────────────────────────────────────────────────────────┐
│  Browser / Mobile App                                            │
│  User authenticates to Okta → receives JWT                      │
└────────────────┬────────────────────────────────────────────────┘
                 │
                 │ Authorization: Bearer <JWT>
                 ▼
┌─────────────────────────────────────────────────────────────────┐
│  Istio Ingress Gateway (for external traffic)                   │
│  OR Istio Sidecar Proxy (for in-cluster traffic)                │
│                                                                   │
│  RequestAuthentication:                                          │
│  - Validates JWT signature against Okta JWKS                    │
│  - Verifies iss (issuer) matches OKTA_ISSUER                    │
│  - Verifies aud (audience) matches OKTA_AUDIENCE                │
│  - Verifies exp (expiration) is future                          │
│                                                                   │
│  AuthorizationPolicy:                                            │
│  - Requires valid JWT for all ingress traffic                   │
│  - Rejects requests without JWT or with invalid JWT             │
│                                                                   │
│  Header Injection:                                               │
│  - Extracts 'email' claim → x-user-email header                 │
│  - Extracts 'groups' claim → x-user-groups header               │
└────────────────┬────────────────────────────────────────────────┘
                 │
                 │ Request with validated headers
                 ▼
┌─────────────────────────────────────────────────────────────────┐
│  Application Pod (with Istio sidecar)                           │
│                                                                   │
│  HTTP Middleware (Spring Filter, ASP.NET Middleware, etc.):     │
│  - Reads x-user-email header                                    │
│  - Reads x-user-groups header                                   │
│  - Stores in request context (ThreadLocal, AsyncLocal)          │
│                                                                   │
│  Database Connection Interceptor:                                │
│  - On connection checkout: BEGIN                                │
│  - Injects: SET LOCAL app.current_user = <x-user-email>         │
│  - Injects: SET LOCAL app.current_roles = <x-user-groups>       │
│  - Returns connection to app code                               │
│                                                                   │
│  Business Logic:                                                 │
│  - App developer writes normal queries                          │
│  - RLS policies automatically filter based on session vars      │
│                                                                   │
│  Connection Return:                                              │
│  - COMMIT (clears SET LOCAL variables)                          │
│  - Connection returned to pool                                  │
└────────────────┬────────────────────────────────────────────────┘
                 │
                 │ postgresql://pgb_app_user@pgbouncer-app:5432/production
                 ▼
┌─────────────────────────────────────────────────────────────────┐
│  PgBouncer App Pool                                              │
│  - Authenticates to CockroachDB as pgb_app_user (certificate)  │
│  - Transaction pooling preserves SET LOCAL variables            │
└────────────────┬────────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────────────┐
│  CockroachDB Cluster                                             │
│  - RLS policies filter rows based on current_setting()          │
└─────────────────────────────────────────────────────────────────┘
```

### What Istio Does NOT Do

❌ **Does not handle database authentication** - Applications still connect to PgBouncer with service account credentials  
❌ **Does not inject SET LOCAL directly** - Application middleware owns this responsibility  
❌ **Does not apply to service-to-service calls** - Use Case 2 uses Istio mTLS without JWT  
❌ **Does not apply to batch/admin pools** - Use Cases 5, 6 use service accounts directly  
❌ **Does not apply to direct CockroachDB access** - Use Cases 4, 7 bypass PgBouncer entirely  

## Use Case Support (Detailed Implementation Guide)

This section maps each use case from the **CockroachDB Connectivity Guide** to the Phase 6 Istio implementation.

### Summary Table

| Use Case | Istio Involved? | PgBouncer? | Implementation Status |
|----------|----------------|------------|----------------------|
| 1. End User via Application | ✅ **YES** | ✅ app pool | **Phase 6 focus** |
| 2A. Microservice-to-Microservice (with user) | ✅ **YES** (header propagation) | ✅ app pool | **Phase 6 focus** |
| 2B. Service-to-Service (no user) | ✅ mTLS only | ✅ app pool | **Phase 6 (implicit)** |
| 3. Power BI / Analytics | ❌ No | ⚠️ analytics pool | **Future** (separate pool needed) |
| 4. DBA / Developer Direct | ❌ No | ❌ Direct CRDB | **Phase 4** (native JWT auth) |
| 5. Batch / ETL Jobs | ❌ No | ✅ batch pool | **Phase 5** (complete) |
| 6. Admin / Ops Tooling | ❌ No | ✅ admin pool | **Phase 5** (complete) |
| 7. Flyway Schema Migrations | ❌ No | ❌ Direct CRDB | **Phase 7** (planned) |
| 8. NiFi Pipeline | ❌ No | ✅ multiple pools | **Phase 5** (complete) |

---

### ✅ Use Case 1: End User via Application (RLS Enforced)

**From Connectivity Guide:**
- Identity flow: Browser → Okta/WSOC → JWT → Istio → App Service → PgBouncer app → CRDB
- Pool: PgBouncer transaction pool (pgb_app_user, port 5432)
- Transaction pattern: Pattern A (explicit BEGIN, SET LOCAL, client retry on 40001)
- RLS: Enforced via `current_setting('app.current_user')` and `current_setting('app.current_roles')`

**Phase 6 Implementation:**

1. **Istio RequestAuthentication**
   - Validates JWT signature against `${OKTA_JWKS_URL}`
   - Verifies issuer matches `${OKTA_ISSUER}`
   - Verifies audience matches `${OKTA_AUDIENCE}`
   - Extracts `email` claim → `x-user-email` header
   - Extracts `groups` claim → `x-user-groups` header

2. **Istio AuthorizationPolicy**
   - Requires valid JWT for all ingress traffic to application services
   - Rejects requests without JWT or with invalid JWT (401 Unauthorized)

3. **Application Middleware** (provided as reference implementations)
   - HTTP Middleware: Reads `x-user-email` and `x-user-groups` headers
   - Stores in request context (ThreadLocal for Java, AsyncLocal for C#, contextvars for Python)
   - Database Connection Interceptor: Injects `SET LOCAL` on connection checkout

4. **Database Pattern**
   ```sql
   BEGIN;
   SET LOCAL app.current_user = 'alice@example.com';  -- From x-user-email
   SET LOCAL app.current_roles = 'crdb_advisor_team_east';  -- From x-user-groups
   -- Business queries execute here (RLS filters rows)
   COMMIT;  -- Clears SET LOCAL automatically
   ```

**App Team Responsibility:**
- Integrate provided middleware into application framework
- Ensure pods are deployed in namespace with `istio-injection=enabled` label
- Write business queries normally (RLS is transparent)

---

### ✅ Use Case 2: Microservice-to-Microservice

**IMPORTANT:** Use Case 2 has **two distinct patterns** depending on whether user identity needs to be propagated.

---

#### Use Case 2A: WITH User Context Propagation (Most Common)

**Scenario:** User → Service A → Service B → Service C → PgBouncer → CockroachDB

**From Connectivity Guide:**
- Identity flow: User JWT validated at ingress → headers propagated through service chain
- Pool: PgBouncer transaction pool (pgb_app_user, port 5432)
- Transaction pattern: **Pattern A** (explicit BEGIN, SET LOCAL, RLS enforced)
- RLS: **Enforced** - each service in the chain maintains user identity
- Headers: `x-user-email`, `x-user-groups` propagated through entire call chain

**Phase 6 Implementation:**

1. **Header Propagation Chain**
   ```
   External User (with JWT)
     ↓ Authorization: Bearer <JWT>
   Istio Ingress Gateway
     ↓ Validates JWT, injects x-user-email, x-user-groups
   Service A (Frontend)
     ↓ Reads headers, propagates to outbound calls
   Service B (Backend)
     ↓ Reads headers, propagates to outbound calls
   Service C (Data Layer)
     ↓ Reads headers, injects SET LOCAL
   PgBouncer → CockroachDB (RLS enforced)
   ```

2. **Middleware Requirements**
   - **Incoming:** Read `x-user-email` and `x-user-groups` from request headers
   - **Outbound:** Propagate headers to all downstream HTTP calls
   - **Database:** Inject `SET LOCAL` on connection checkout

3. **Java Example (Spring Boot)**
   ```java
   // Outbound call - RestTemplate auto-propagates headers via interceptor
   @Service
   public class FrontendService {
       @Autowired
       private RestTemplate restTemplate;  // Configured with UserContextInterceptor
       
       public Order createOrder(OrderRequest request) {
           // Call backend service - headers automatically included
           InventoryResponse inventory = restTemplate.postForObject(
               "http://backend-service/api/inventory/check",
               request,
               InventoryResponse.class
           );
           
           // Backend service will receive x-user-email and x-user-groups headers
           // Backend can then call database with same user context
       }
   }
   ```

4. **C# Example (ASP.NET Core)**
   ```csharp
   // Outbound call - HttpClient auto-propagates headers via DelegatingHandler
   public class FrontendService
   {
       private readonly IHttpClientFactory _httpClientFactory;
       
       public async Task<Order> CreateOrder(OrderRequest request)
       {
           var client = _httpClientFactory.CreateClient("backend-service");
           
           // Call backend service - headers automatically included
           var inventory = await client.PostAsJsonAsync(
               "http://backend-service/api/inventory/check", 
               request
           );
           
           // Backend service will receive x-user-email and x-user-groups headers
       }
   }
   ```

5. **Python Example (FastAPI)**
   ```python
   # Outbound call - httpx auto-propagates headers via event hooks
   class FrontendService:
       def __init__(self, http_client: httpx.AsyncClient):
           self.http_client = http_client  # Configured with header propagation hook
       
       async def create_order(self, request: OrderRequest):
           # Call backend service - headers automatically included
           inventory = await self.http_client.post(
               "http://backend-service/api/inventory/check",
               json=request.dict()
           )
           
           # Backend service will receive x-user-email and x-user-groups headers
   ```

6. **Database Pattern (Any Service in Chain)**
   ```sql
   -- Connection wrapper automatically injects:
   BEGIN;
   SET LOCAL app.current_user = '<x-user-email from header>';
   SET LOCAL app.current_roles = '<x-user-groups from header>';
   
   -- Business queries execute with RLS filtering
   SELECT * FROM accounts WHERE status = 'active';
   -- Returns only accounts accessible to this user
   
   COMMIT;  -- Clears SET LOCAL automatically
   ```

**App Team Responsibility:**
- Configure HTTP client with header propagation interceptor (provided in reference implementations)
- Ensure all outbound calls use configured HTTP client (RestTemplate, HttpClient, httpx)
- Database connection wrapper handles SET LOCAL automatically
- Business code writes normal queries (RLS is transparent)

**Critical:** Every service in the chain MUST propagate headers. If any service breaks the chain, downstream services lose user context and RLS fails open (returns zero rows or uses service account permissions).

---

#### Use Case 2B: WITHOUT User Context (Service Account Operations)

**Scenario:** Scheduled Job → Service A → PgBouncer → CockroachDB

**From Connectivity Guide:**
- Identity flow: Istio mTLS with SPIFFE/X.509 service identity - no JWT, no user email
- Pool: PgBouncer transaction pool (pgb_app_user, port 5432)
- Transaction pattern: **Pattern B** (autocommit, CRDB retries internally)
- RLS: **Not applicable** (service account RBAC controls access)
- No SET LOCAL injection (app.current_user not set)

**Phase 6 Implementation:**

1. **Istio mTLS Only**
   - Automatic mutual TLS between services (handled by Istio sidecar)
   - SPIFFE identity for service authentication
   - No JWT validation needed
   - No user context headers

2. **Application Code**
   - No header propagation needed (no headers to propagate)
   - Connect to PgBouncer with service account credentials
   - Use autocommit mode (Pattern B)
   - No `SET LOCAL` needed

3. **Database Pattern**
   ```java
   // No explicit transaction, no SET LOCAL
   List<Currency> currencies = jdbcTemplate.query(
       "SELECT code, name FROM currencies WHERE active = true",
       currencyRowMapper
   );
   // CockroachDB handles retries internally
   // Service account RBAC controls table access
   ```

**Use Cases:**
- Scheduled batch jobs (nightly reconciliation, cleanup tasks)
- System health checks
- Reference data lookups
- Service-to-service calls with no originating user request

**App Team Responsibility:**
- Deploy in namespace with `istio-injection=enabled` for mTLS
- No user context middleware needed
- Use simple query patterns (lookups, reference data)
- Ensure queries don't access RLS-protected tables (will return zero rows)

---

### ⚠️ Use Case 3: Power BI / Analytics (Session Pooling, Read-Only)

**From Connectivity Guide:**
- Identity flow: Power BI connects with pgb_analytics_user credential via ODBC
- Pool: PgBouncer **session pool** (pgb_analytics_user, port 5433) - **NOT DEPLOYED**
- Target: CockroachDB PCR Standby (West) for read-only analytics
- Transaction pattern: Pattern B (autocommit, Power BI manages cursors)
- RLS: Not enforced at CRDB level (analytics schema has pre-filtered views)

**Phase 6 Status:**

❌ **NOT IMPLEMENTED** - Requires separate analytics pool with:
- Session pooling mode (not transaction pooling)
- Connection to PCR Standby (West region)
- Different service account (pgb_analytics_user with analytics_ro role)

**Future Work:**
- Add analytics pool configuration to Phase 5
- Configure PgBouncer session pooling for long-lived Power BI connections
- Route to PCR Standby for analytics isolation

---

### ❌ Use Case 4: DBA / Developer Direct Access

**From Connectivity Guide:**
- Identity flow: Developer → Okta OIDC → CRDB native OIDC auth (no PgBouncer)
- Pool: None (direct CockroachDB connection)
- Transaction pattern: Developer-managed (psql or tooling client handles transactions)
- RLS: Applied per granted parent role (fiduciary_admin has BYPASSRLS, fiduciary_analyst does not)
- Provisioning: CRDB user created automatically with OIDC mapping on first login

**Phase 6 Status:**

❌ **NOT APPLICABLE** - Istio not involved

**Already Supported By:**
- **Phase 4**: CockroachDB JWT authentication configuration
- **Phase 0**: Okta OIDC application setup

**Connection Method:**
- Developers use crdb-sql.py script from okta-crdb-sync repository
- JWT passed as password: `postgresql://<email>:<JWT>@crdb-host:26257/production?options=--crdb:jwt_auth_enabled=true`
- CockroachDB validates JWT natively, auto-provisions user, assigns roles based on groups claim

---

### ❌ Use Case 5: Batch / ETL Jobs

**From Connectivity Guide:**
- Identity flow: Service account credential only - no JWT, no user identity
- Pool: PgBouncer transaction pool (pgb_batch_user, port 5432)
- Transaction pattern: Pattern B for individual lookups; Pattern A for large batch writes
- RLS: Not applied (batch_svc role has RBAC access; no per-user row filtering)

**Phase 6 Status:**

❌ **NOT APPLICABLE** - Istio not involved (service account, no JWT)

**Already Supported By:**
- **Phase 5**: PgBouncer batch pool deployed
- **Phase 4**: pgb_batch_user service account with admin role + BYPASSRLS

**Connection Method:**
- Batch jobs connect with service account credentials
- No JWT, no headers, no middleware
- RBAC enforces schema/table access, RLS is bypassed

---

### ❌ Use Case 6: Admin / Ops Tooling

**From Connectivity Guide:**
- Identity flow: Internal VPN + MFA → PgBouncer admin pool (no external exposure)
- Pool: PgBouncer admin pool (pgb_admin_user, port 5434) with connection limit
- Transaction pattern: Explicit (DBA-managed DDL and operational queries)
- RLS: BYPASSRLS (admin role sees all rows regardless of owner_email)
- Audit: All admin pool sessions logged; DDL changes tracked via Flyway migration history

**Phase 6 Status:**

❌ **NOT APPLICABLE** - Istio not involved (internal VPN, no ingress gateway)

**Already Supported By:**
- **Phase 5**: PgBouncer admin pool deployed
- **Phase 4**: pgb_admin_user service account with admin role + BYPASSRLS
- **Network Policies**: Admin pool accessible only from admin tools (separate namespace or VPN)

---

### ❌ Use Case 7: Flyway Schema Migrations (DDL)

**From Connectivity Guide:**
- Identity flow: Kubernetes Job with flyway_svc service account - no JWT, no user identity
- Pool: **Direct CockroachDB connection** (DDL cannot run through transaction pool)
- Transaction pattern: Each migration is a single DDL statement; CRDB executes online DDL without blocking
- Access control: flyway_svc has CREATE, ALTER, DROP, INSERT on flyway_schema_history
- Schema history: Flyway tracks applied migrations in flyway_schema_history per database

**Phase 6 Status:**

❌ **NOT APPLICABLE** - Istio not involved (direct CRDB connection)

**Future Work:**
- **Phase 7**: Flyway deployment
- Kubernetes Job (initContainer or pre-deploy Job)
- Vault-injected credentials and certificates
- Exits 0 on success, non-zero blocks rollout

---

### ❌ Use Case 8: NiFi Pipeline Orchestration (Patterns 1-3)

**From Connectivity Guide:**
- Identity flow: NiFi service within EKS - no end-user identity
- Pool: PgBouncer transaction pool per database (NiFi JDBC Controller Services)
- Transaction patterns:
  - Pattern 1 (Batch CSV → Kafka → Staging): Pattern B (autocommit inserts, CRDB retries)
  - Pattern 2 (Streaming → Kafka → Staging): Pattern B (same as Pattern 1)
  - Pattern 3 (Validated Staging → MERGE → Production): Pattern A (explicit txn, client-side retry)
- Multi-database routing: NiFi configures one JDBC Controller per database (metadata, staging, production)

**Phase 6 Status:**

❌ **NOT APPLICABLE** - Istio not involved (service account, no JWT)

**Already Supported By:**
- **Phase 5**: PgBouncer pools for metadata, staging, production databases
- **Reference Implementation**: sample-data-pipeline demonstrates NiFi patterns

**Connection Method:**
- NiFi JDBC Controller Service per database/pool combination
- Service account credentials (nifi_svc)
- No JWT, no headers, no middleware

## Phase 6 Components

### 1. Istio Control Plane (istiod)

Deployed to `istio-system` namespace:
- Service mesh control plane
- Configuration distribution
- Certificate management for mTLS

### 2. Istio Ingress Gateway

**Purpose:** External entry point for applications that need to validate JWTs from external users

**Configuration:**
- AWS Network Load Balancer
- Ports: 80 (HTTP), 443 (HTTPS)
- RequestAuthentication resource validates JWT
- AuthorizationPolicy requires valid JWT

**When to use:**
- Mobile apps connecting to backend APIs
- Web frontends (SPAs) connecting to backend services
- External tools that obtain JWT from Okta

**NOT needed for:**
- In-cluster applications (use sidecar injection instead)
- Direct database access (Use Case 4, 7)
- Service accounts (Use Cases 2, 5, 6, 8)

### 3. Istio Sidecar Injection

**Purpose:** Automatically inject Envoy proxy into application pods for mTLS and JWT validation

**Configuration:**
- Label namespace: `istio-injection=enabled`
- Sidecar automatically injected into all pods in labeled namespaces
- mTLS between services
- JWT validation at pod level (for Use Case 1)

**Enabled for:**
- Application namespaces where Use Case 1 applies
- Any namespace with user-facing services requiring JWT validation

**Disabled for:**
- `cockroachdb` namespace (PgBouncer and CockroachDB don't need sidecars)
- `istio-system` namespace
- `kube-system` namespace

### 4. RequestAuthentication Resource

Validates JWT tokens against Okta JWKS endpoint:

```yaml
apiVersion: security.istio.io/v1beta1
kind: RequestAuthentication
metadata:
  name: jwt-auth-okta
  namespace: <app-namespace>
spec:
  jwtRules:
  - issuer: "${OKTA_ISSUER}"
    jwksUri: "${OKTA_JWKS_URL}"
    audiences:
    - "${OKTA_AUDIENCE}"
    outputClaimToHeaders:
    - header: "x-user-email"
      claim: "email"
    - header: "x-user-groups"
      claim: "groups"
```

### 5. AuthorizationPolicy Resource

Requires valid JWT for all ingress traffic:

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: require-jwt
  namespace: <app-namespace>
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        requestPrincipals: ["*"]  # Must have valid JWT
```

## Application Middleware Implementation

Application teams must implement middleware to consume Istio-injected headers and set up database context. Reference implementations are provided for:

### Java (Spring Boot)

**Pattern:** Same middleware approach as Python example in TESTING_CHECKLIST Test 9

**Implementation Requirements:**
- Servlet Filter to read Istio-injected headers (`x-user-email`, `x-user-groups`)
- ThreadLocal storage for request context
- Connection wrapper to inject `SET LOCAL` before query execution
- Spring `@Transactional` integration to ensure session variables are set per transaction

**Key Pattern:**
```java
// Servlet Filter
public class UserContextFilter implements Filter {
    public void doFilter(ServletRequest request, HttpServletResponse response, FilterChain chain) {
        String userEmail = request.getHeader("x-user-email");
        String userGroups = request.getHeader("x-user-groups");
        UserContext.set(userEmail, userGroups);  // ThreadLocal
        chain.doFilter(request, response);
        UserContext.clear();
    }
}

// Connection Wrapper
connection.prepareStatement("SET LOCAL app.current_user = ?").execute(userEmail);
connection.prepareStatement("SET LOCAL app.current_roles = ?").execute(userGroups);
```

### C# (ASP.NET Core)

**Pattern:** Same middleware approach as Python example in TESTING_CHECKLIST Test 9

**Implementation Requirements:**
- ASP.NET Middleware to read Istio-injected headers (`x-user-email`, `x-user-groups`)
- AsyncLocal storage for request context
- DbConnection wrapper to inject `SET LOCAL` before query execution
- Entity Framework integration to set session variables automatically

**Key Pattern:**
```csharp
// Middleware
public class UserContextMiddleware {
    public async Task InvokeAsync(HttpContext context, RequestDelegate next) {
        var userEmail = context.Request.Headers["x-user-email"];
        var userGroups = context.Request.Headers["x-user-groups"];
        UserContext.Current = new UserContext(userEmail, userGroups);  // AsyncLocal
        await next(context);
    }
}

// DbConnection Wrapper
await connection.ExecuteAsync("SET LOCAL app.current_user = @user", new { user = userEmail });
await connection.ExecuteAsync("SET LOCAL app.current_roles = @roles", new { roles = userGroups });
```

### Python (Flask/FastAPI)

**Concept Example:** See Test 9 in `TESTING_CHECKLIST.md` for a simple demonstration (inline code for clarity)

**Production Pattern:** Use middleware/decorator to automatically handle SET LOCAL for every request

#### Flask Middleware Pattern

```python
from flask import Flask, request, g
from contextvars import ContextVar
import psycopg2
from functools import wraps

app = Flask(__name__)

# Thread-safe context storage
user_context = ContextVar('user_context', default=None)

# Middleware - runs before every request
@app.before_request
def extract_user_context():
    """Read Istio-injected headers and store in request context"""
    user_email = request.headers.get('x-user-email')
    user_groups = request.headers.get('x-user-groups')
    
    if not user_email:
        return jsonify({"error": "Missing user identity"}), 401
    
    user_context.set({
        'email': user_email,
        'groups': user_groups
    })

# Database connection wrapper
class CRDBConnection:
    def __init__(self):
        self.conn = psycopg2.connect(
            host="pgbouncer-app.cockroachdb.svc.cluster.local",
            port=5432,
            database="production",
            user="test",
            sslmode="require"
        )
        self._inject_context()
    
    def _inject_context(self):
        """Automatically inject user context via SET LOCAL"""
        ctx = user_context.get()
        if ctx:
            cur = self.conn.cursor()
            cur.execute("SET LOCAL app.current_user = %s", (ctx['email'],))
            cur.execute("SET LOCAL app.current_roles = %s", (ctx['groups'],))
            cur.close()
    
    def __enter__(self):
        return self.conn
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        if exc_type:
            self.conn.rollback()
        else:
            self.conn.commit()
        self.conn.close()

# Business logic - no SET LOCAL needed!
@app.route('/api/accounts')
def get_accounts():
    """Developer writes normal queries - RLS applies automatically"""
    with CRDBConnection() as conn:
        cur = conn.cursor()
        cur.execute("SELECT * FROM accounts WHERE status = 'active'")
        results = cur.fetchall()
    
    return jsonify(results)
```

#### FastAPI Middleware Pattern

```python
from fastapi import FastAPI, Request, Depends
from contextvars import ContextVar
import psycopg2

app = FastAPI()
user_context = ContextVar('user_context', default=None)

# Middleware
@app.middleware("http")
async def extract_user_context(request: Request, call_next):
    user_email = request.headers.get('x-user-email')
    user_groups = request.headers.get('x-user-groups')
    
    if not user_email:
        return JSONResponse({"error": "Missing user identity"}, status_code=401)
    
    user_context.set({'email': user_email, 'groups': user_groups})
    response = await call_next(request)
    return response

# Dependency injection for database connection
def get_db():
    conn = psycopg2.connect(...)
    ctx = user_context.get()
    if ctx:
        cur = conn.cursor()
        cur.execute("SET LOCAL app.current_user = %s", (ctx['email'],))
        cur.execute("SET LOCAL app.current_roles = %s", (ctx['groups'],))
        cur.close()
    
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

# Business logic
@app.get("/api/accounts")
def get_accounts(db = Depends(get_db)):
    cur = db.cursor()
    cur.execute("SELECT * FROM accounts WHERE status = 'active'")
    return cur.fetchall()
```

**Key Benefits:**
- ✅ SET LOCAL automatically applied to every request (no code duplication)
- ✅ Developers write normal queries (RLS is transparent)
- ✅ Context propagates through entire request lifecycle
- ✅ Connection wrapper ensures session variables are set before any query

## Security Model

### Trust Chain

1. **Okta** - Issues JWT with cryptographic signature
2. **Istio** - Validates JWT signature against Okta JWKS (public key)
3. **Application Middleware** - Trusts headers injected by Istio (network enforced)
4. **PgBouncer** - Authenticates to CockroachDB with service account certificate
5. **CockroachDB** - Enforces RLS based on SET LOCAL session variables

### What We Trust

✅ Okta to sign JWTs correctly  
✅ Istio to validate JWT and inject correct headers  
✅ Network policies to prevent applications from bypassing Istio  
✅ Application middleware to set session variables from headers (it's our code)  
✅ CockroachDB RBAC to enforce service account permission boundaries  

### What We Don't Trust

❌ End users to provide correct identity (JWT cryptographically verified)  
❌ Applications to bypass Istio (network policies enforce sidecar)  
❌ Service accounts to escalate privileges (RBAC enforced by CockroachDB)  
❌ Session variables without validation chain (Istio → JWT → Okta)  

### Defense in Depth

Even if one layer fails, others prevent compromise:

- **Istio bypassed?** → Still bounded by service account permissions (can't escalate to admin)
- **SET LOCAL forgotten?** → RLS policy returns zero rows (fail-closed)
- **JWT stolen?** → Still requires network access to in-cluster services
- **RLS policy bug?** → Still can't perform DDL or access other databases

## Deployment Steps

### Prerequisites

- Phase 0-5 complete
- Okta OIDC configured with JWKS endpoint
- `istioctl` installed: `brew install istioctl` (required for generating manifests; cluster commands won't work with self-signed certificates)
- Application namespace(s) created

### Step 1: Install Istio

```bash
cd manifests/phase6-istio
./setup.sh
```

The script will:
1. Install Istio control plane (istiod) in `istio-system` namespace
2. Deploy Istio ingress gateway (optional, based on config)
3. Enable sidecar injection on specified namespaces
4. Create RequestAuthentication resource
5. Create AuthorizationPolicy resource
6. Verify installation

### Step 2: Deploy Application Middleware

Application teams integrate reference middleware into their applications:

1. Copy reference implementation for your stack (Java/C#/Python)
2. Configure Okta issuer/audience settings
3. Deploy application with `istio-injection=enabled` label on namespace
4. Verify sidecar injection: `kubectl get pods -n <namespace>` (should show 2/2 READY)
5. Test JWT validation with sample requests

### Step 3: Validate

See validation steps in README.md

## Configuration

### Required Environment Variables

```bash
# Okta OIDC Configuration
export OKTA_ISSUER="https://your-domain.okta.com/oauth2/default"
export OKTA_JWKS_URL="https://your-domain.okta.com/oauth2/default/v1/keys"
export OKTA_CLIENT_ID="0oa9abcd1234efgh5678"
export OKTA_AUDIENCE="example-crdb-cluster"

# Application Namespaces (comma-separated)
export APP_NAMESPACES="app-production,app-staging"

# Istio Ingress (optional - only if exposing external entry point)
export ENABLE_ISTIO_INGRESS="false"  # Default: false (sidecar-only mode)
```

### Network Policies

Phase 6 does NOT create network policies to enforce Istio sidecar requirement. This is intentional - application teams should add network policies to their namespaces if they want to prevent pods without sidecars from accessing PgBouncer.

Example NetworkPolicy (application team creates):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: require-istio-sidecar
  namespace: app-production
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: pgbouncer
    ports:
    - protocol: TCP
      port: 5432
    # Only allow if pod has Istio sidecar
    from:
    - podSelector:
        matchLabels:
          security.istio.io/tlsMode: istio
```

## Testing Plan

### 1. JWT Validation

Test that Istio correctly validates JWT tokens:

```bash
# Valid JWT - should succeed
curl -H "Authorization: Bearer $(cat valid-jwt.txt)" \
  http://<app-service>/api/accounts

# Invalid JWT - should fail with 401
curl -H "Authorization: Bearer invalid-token" \
  http://<app-service>/api/accounts

# No JWT - should fail with 401
curl http://<app-service>/api/accounts
```

### 2. Header Injection

Verify Istio injects correct headers:

```bash
# Deploy test echo service that prints request headers
kubectl apply -f test/echo-service.yaml

# Send request with valid JWT
curl -H "Authorization: Bearer $(cat valid-jwt.txt)" \
  http://echo-service/headers

# Verify output contains:
# x-user-email: alice@example.com
# x-user-groups: crdb_advisor_team_east
```

### 3. RLS Enforcement

Test that RLS correctly filters rows based on user identity:

```bash
# Connect as user from advisor_team_east
# Should see only accounts for party_ids assigned to that role
curl -H "Authorization: Bearer $(cat user-east-jwt.txt)" \
  http://<app-service>/api/accounts

# Connect as user from advisor_team_west
# Should see different set of accounts
curl -H "Authorization: Bearer $(cat user-west-jwt.txt)" \
  http://<app-service>/api/accounts
```

### 4. Service-to-Service (No JWT)

Test that microservice-to-microservice calls work without JWT:

```bash
# Deploy test microservice without JWT
kubectl apply -f test/internal-service.yaml

# Call from internal service (mTLS only, no JWT)
kubectl exec -it internal-service -- curl http://app-service/api/health

# Should succeed (no JWT required for non-RLS endpoints)
```

## Rollback Plan

If Phase 6 deployment fails or causes issues:

```bash
# Remove Istio installation (use kubectl - istioctl has certificate issues)
kubectl delete namespace istio-system
kubectl delete crds -l app=istio

# Remove namespace labels
kubectl label namespace <app-namespace> istio-injection-

# Remove RequestAuthentication and AuthorizationPolicy
kubectl delete requestauthentication --all -n <app-namespace>
kubectl delete authorizationpolicy --all -n <app-namespace>

# Restart application pods to remove sidecars
kubectl rollout restart deployment -n <app-namespace>
```

Applications will continue to work without Istio - they just won't have JWT validation at the network layer. App teams will need to implement JWT validation in their application code if Istio is removed.

## Success Criteria

Phase 6 is complete when:

- ✅ Istio control plane running in `istio-system` namespace
- ✅ Sidecar injection enabled on application namespaces
- ✅ RequestAuthentication resource validates JWT against Okta JWKS
- ✅ AuthorizationPolicy requires valid JWT for ingress traffic
- ✅ Headers `x-user-email` and `x-user-groups` injected correctly
- ✅ Reference middleware implementations available for Java, C#, Python
- ✅ Test application deployed with working JWT validation
- ✅ RLS enforcement works end-to-end (JWT → headers → SET LOCAL → filtered queries)
- ✅ Documentation updated in ARCHITECTURE.md

## Next Steps

After Phase 6:

**Phase 7: Flyway Schema Migrations**
- Deploy Flyway for automated schema migrations
- Use Case 7 from Connectivity Guide
- Direct CockroachDB connection (bypass PgBouncer for DDL)
- Kubernetes Job with flyway_svc service account

## References

- [CockroachDB Connectivity Guide](../../generated/references/0.4%20CockroachDB%20Connectivity%20Guide_%20User%20Access%20Design.pdf)
- [Istio RequestAuthentication](https://istio.io/latest/docs/reference/config/security/request_authentication/)
- [Istio AuthorizationPolicy](https://istio.io/latest/docs/reference/config/security/authorization-policy/)
- [Okta OIDC Documentation](https://developer.okta.com/docs/guides/implement-oauth-for-okta/main/)
