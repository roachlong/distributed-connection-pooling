# Phase 6: Istio Service Mesh

Deploys Istio service mesh for **JWT authentication validation** and **user identity propagation** to application services. Istio validates Okta JWT tokens at the ingress gateway and injects user identity headers (`x-user-email`, `x-user-groups`) that application middleware uses to enforce Row-Level Security (RLS) in CockroachDB.

## What's Deployed

**Istio Components:**
- **Istio Control Plane** (istiod): Service mesh control plane in `istio-system` namespace
- **Istio Ingress Gateway** (optional): External entry point with AWS Network Load Balancer for testing from local workstation
- **Istio Sidecar Injection**: Enabled on `app-services` namespace for JWT validation and header injection

**Security Resources (in app-services namespace):**
- **RequestAuthentication**: Validates JWT tokens from Okta JWKS endpoint, extracts claims (email, groups)
- **AuthorizationPolicy**: Requires valid JWT for all ingress traffic
- **Gateway**: Configures ingress for HTTP/HTTPS traffic (ports 80, 443)
- **VirtualService** (example template): Routes HTTP requests to application services

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  External Client (Human User, Mobile App, Web Browser)               │
│  - Obtains JWT token from Okta OAuth2 flow                           │
│  - Token contains: email (user identity), groups (role memberships)  │
└─────────────────┬───────────────────────────────────────────────────┘
                  │
                  │ HTTP request with JWT in Authorization header
                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Istio Ingress Gateway (Optional - for external access)              │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  RequestAuthentication (app-services namespace)              │    │
│  │  - Validates JWT signature using Okta JWKS                   │    │
│  │  - Verifies issuer (iss) matches OKTA_ISSUER                 │    │
│  │  - Verifies audience (aud) matches OKTA_AUDIENCE             │    │
│  │  - Extracts email and groups claims                          │    │
│  │  - Injects headers: x-user-email, x-user-groups              │    │
│  └─────────────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  AuthorizationPolicy (app-services namespace)                │    │
│  │  - Requires valid JWT (rejects if validation failed)         │    │
│  │  - Only allows traffic with requestPrincipals present        │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────┬───────────────────────────────────────────────────┘
                  │
                  │ HTTP request with x-user-email, x-user-groups headers
                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Application Service (app-services namespace)                        │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  Istio Sidecar Proxy (Envoy)                                 │    │
│  │  - Forwards request with injected headers to app container   │    │
│  └─────────────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  Application Container (Java/C#/Python/Node.js)              │    │
│  │  - Reads x-user-email and x-user-groups from HTTP headers    │    │
│  │  - Middleware creates database connection with user context  │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────┬───────────────────────────────────────────────────┘
                  │
                  │ Pattern A (RLS Enforced):
                  │   conn = getConnection(pgbouncer-app:5432)
                  │   BEGIN;
                  │   SET LOCAL role = 'user@example.com';  -- from x-user-email
                  │   -- Execute queries (RLS policies applied)
                  │   COMMIT;
                  │
                  │ Pattern B (Service Account Only):
                  │   conn = getConnection(pgbouncer-batch:5433)
                  │   -- Execute queries (no RLS, BYPASSRLS privilege)
                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PgBouncer Pools (cockroachdb namespace, NO Istio sidecar)           │
│  - pgbouncer-app:5432   (App pool - RLS enforced)                    │
│  - pgbouncer-batch:5433 (Batch pool - BYPASSRLS)                     │
│  - pgbouncer-admin:5434 (Admin pool - DBA access)                    │
└─────────────────┬───────────────────────────────────────────────────┘
                  │
                  │ PostgreSQL wire protocol connections
                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  CockroachDB Cluster (cockroachdb namespace)                         │
│  - RLS policies filter rows based on SET LOCAL role                  │
│  - Session variables: app.current_user, app.current_roles            │
│  - Three-tier role architecture: Service Accounts → Parent Roles     │
│    → Okta-Mapped User Roles                                          │
└─────────────────────────────────────────────────────────────────────┘
```

**Key Points:**
- **Istio works at HTTP layer**: Validates JWT tokens, injects headers into HTTP requests
- **Application middleware**: Reads `x-user-email` and `x-user-groups` headers, creates database connection with `SET LOCAL role`
- **PgBouncer has NO Istio sidecar**: It's a backend PostgreSQL connection pool, not an HTTP service
- **Two patterns**: Pattern A (user context + RLS) for app pool, Pattern B (service account only) for batch pool

## Supported Use Cases

Phase 6 supports the following patterns from the [CockroachDB Connectivity Guide](../../generated/references/0.4%20CockroachDB%20Connectivity%20Guide_%20User%20Access%20Design.pdf):

| Use Case | Supported | Implementation |
|----------|-----------|----------------|
| **Use Case 1**: End User via Application | ✅ Yes | JWT validated at ingress → headers injected → app middleware uses `SET LOCAL role` |
| **Use Case 2A**: Microservice-to-Microservice WITH user context | ✅ Yes | Headers propagated through service call chain → each service uses `SET LOCAL role` |
| **Use Case 2B**: Service-to-Service WITHOUT user context | ✅ Yes | Istio mTLS only (no JWT) → service account RBAC only |
| **Use Case 3**: Power BI / Analytics | ❌ Future | Requires dedicated analytics pool with session pooling |
| **Use Case 4**: DBA / Developer Direct Access | ❌ Out of Scope | Uses CockroachDB native JWT auth, bypasses Istio |
| **Use Case 5**: Batch / ETL Jobs | ✅ Already Supported (Phase 5) | Service account credentials, no JWT, uses batch pool |
| **Use Case 6**: Third-Party Tools (NiFi, Airflow) | ✅ Already Supported (Phase 5) | Service account credentials, uses data-management namespace |
| **Use Case 7**: SQL Proxy for Local Development | ❌ Out of Scope | Local development workflow, not Istio-based |
| **Use Case 8**: CI/CD Pipeline Access | ✅ Already Supported (Phase 5) | Service account credentials, no JWT |

**For detailed implementation patterns and code examples, see [IMPLEMENTATION_GUIDE.md](IMPLEMENTATION_GUIDE.md).**

## Prerequisites

- **Phase 0 complete**: Okta OIDC application configured with JWKS endpoint
- **Phase 1 complete**: EKS cluster deployed
- **Phase 2 complete**: Vault PKI operational
- **Phase 3 complete**: CockroachDB Operator installed
- **Phase 4 complete**: CockroachDB cluster with JWT authentication
- **Phase 5 complete**: Three PgBouncer pools deployed
- **istioctl installed**: `brew install istioctl` (required for generating manifests only; debugging commands won't work with self-signed certificates)
- **config.env updated**: Okta configuration (OKTA_ISSUER, OKTA_JWKS_URL, OKTA_AUDIENCE)

**Note:** If your EKS cluster uses self-signed certificates, `istioctl` commands that connect to the cluster (like `istioctl version`, `istioctl analyze`) will fail. The setup script only uses `istioctl manifest generate` (local operation), then applies manifests via `kubectl`.

## Deployment

### Step 1: Verify Okta Configuration

Ensure `config.env` has Okta settings from Phase 0:

```bash
cd /path/to/distributed-connection-pooling/kubernetes/eks
grep OKTA config.env
```

Expected output:
```bash
export OKTA_ISSUER="https://dev-12345678.okta.com/oauth2/default"
export OKTA_JWKS_URL="https://dev-12345678.okta.com/oauth2/default/v1/keys"
export OKTA_CLIENT_ID="0oa9abcd1234efgh5678"
export OKTA_AUDIENCE="example-crdb-cluster"
```

### Step 2: Run Setup Script

```bash
cd manifests/phase6-istio
chmod +x setup.sh
./setup.sh
```

The script will:

1. **Generate Istio Manifests** (local operation, no cluster connection):
   ```bash
   istioctl manifest generate --set profile=default > istio-manifest.yaml
   ```

2. **Apply Manifests via kubectl**:
   ```bash
   kubectl create namespace istio-system
   kubectl apply -f istio-manifest.yaml
   ```

3. **Deploy Istio Control Plane (istiod)** in `istio-system` namespace

4. **Deploy Istio Ingress Gateway** (optional, if `ENABLE_ISTIO_INGRESS=true`):
   - Service type: LoadBalancer with AWS NLB
   - Exposes ports: 80 (HTTP), 443 (HTTPS)
   - For testing from local workstation

5. **Create Application Namespace** with sidecar injection:
   ```bash
   kubectl create namespace app-services
   kubectl label namespace app-services istio-injection=enabled
   ```

6. **Create RequestAuthentication Resource** (in `app-services` namespace):
   - Name: `jwt-auth-okta`
   - JWKS URI: `$OKTA_JWKS_URL`
   - Issuer: `$OKTA_ISSUER`
   - Audience: `$OKTA_AUDIENCE`
   - Output claims to headers: `x-user-email` (from `email` claim), `x-user-groups` (from `groups` claim)

7. **Create AuthorizationPolicy** (in `app-services` namespace):
   - Name: `require-jwt`
   - Requires: valid JWT token for all ingress traffic
   - Rejects: requests without JWT or with invalid JWT

8. **Create Gateway Resource** (optional, if ingress enabled):
   - Name: `app-gateway`
   - Selector: istio-ingressgateway
   - Ports: 80 (HTTP), 443 (HTTPS)
   - Protocol: HTTP/HTTPS
   - For external access to application services

9. **Create Sample VirtualService Template**:
   - Example showing how to route HTTP traffic to your application services
   - Application teams customize this for their specific services
   - Routes HTTP requests (e.g., `/api/*`) to application service pods

10. **Wait for Istio components to be ready**

11. **Display ingress gateway external endpoint** (if enabled)

## Validation

### Check Istio Installation

```bash
# Verify Istio control plane
kubectl get pods -n istio-system

# Expected output:
# NAME                                    READY   STATUS    RESTARTS   AGE
# istiod-xxxxxxxxxx-xxxxx                 1/1     Running   0          2m
# istio-ingressgateway-xxxxxxxxxx-xxxxx   1/1     Running   0          2m

# Check Istio version (using kubectl - istioctl has certificate issues with self-signed certs)
kubectl get deployment -n istio-system istiod -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# Expected: docker.io/istio/pilot:1.20.2
```

### Check Namespace Configuration

```bash
# Verify app-services namespace has sidecar injection enabled
kubectl get namespace app-services -o jsonpath='{.metadata.labels.istio-injection}' && echo
# Expected: enabled

# Verify namespace exists
kubectl get namespace app-services

# Note: PgBouncer pods in cockroachdb namespace do NOT have Istio sidecars
# The cockroachdb namespace should NOT have istio-injection label
kubectl get namespace cockroachdb -o jsonpath='{.metadata.labels.istio-injection}' && echo
# Expected: (empty or "null")
```

### Check Security Resources

```bash
# Check RequestAuthentication in app-services namespace
kubectl get requestauthentication -n app-services

# Expected output:
# NAME            AGE
# jwt-auth-okta   2m

# Describe to see details (verify Okta configuration and header injection)
kubectl describe requestauthentication jwt-auth-okta -n app-services

# Should show:
# - issuer: <your OKTA_ISSUER>
# - jwksUri: <your OKTA_JWKS_URL>
# - audiences: <your OKTA_AUDIENCE>
# - outputClaimToHeaders: x-user-email (from email), x-user-groups (from groups)

# Check AuthorizationPolicy in app-services namespace
kubectl get authorizationpolicy -n app-services

# Expected output:
# NAME           AGE
# require-jwt    2m
```

### Check Gateway (If Ingress Enabled)

```bash
# Check Gateway in istio-system namespace
kubectl get gateway -n istio-system

# Expected output:
# NAME          AGE
# app-gateway   2m

# VirtualService is created by application teams for their specific services
# See generated/phase6/sample-virtualservice.yaml for template
```

### Get Ingress Gateway External Endpoint

```bash
export INGRESS_HOST=$(kubectl get svc -n istio-system istio-ingressgateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $INGRESS_HOST

# Expected output: a1234567890abcdef-1234567890.us-east-2.elb.amazonaws.com
```

**Important**: It may take 2-3 minutes for the AWS NLB to provision and become healthy.

---

## ✅ Infrastructure Validation Complete

**Phase 6 infrastructure is now deployed.** The sections below provide reference material for understanding JWT flows and configuration details.

**For hands-on testing with a sample application:**
- See [TESTING_CHECKLIST.md](TESTING_CHECKLIST.md) for step-by-step testing with sidecar injection, JWT validation, and header verification

**For implementing your own application:**
- See [IMPLEMENTATION_GUIDE.md](IMPLEMENTATION_GUIDE.md) for detailed use case patterns
- See [reference-implementations/](reference-implementations/) for Java, C#, and Python middleware examples

---

## Reference: JWT Authentication Flow

The sections below explain how JWT authentication works at the HTTP layer (for understanding and troubleshooting). **These are examples only - for hands-on testing, see [TESTING_CHECKLIST.md](TESTING_CHECKLIST.md).**

### Example: Obtain JWT Token from Okta

```bash
# Use Okta's OAuth2 token endpoint (replace with your values)
export JWT=$(curl -s -X POST ${OKTA_ISSUER}/v1/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=${OKTA_CLIENT_ID}" \
  -d "client_secret=your-client-secret" \
  -d "username=advisor-east@example.com" \
  -d "password=user-password" \
  -d "scope=openid profile email groups" \
  | jq -r '.id_token')

echo $JWT
```

### Example: Decode and Verify Token

```bash
# Decode JWT token (install jq if needed: brew install jq)
echo $JWT | cut -d. -f2 | base64 -d | jq .
```

Expected claims:
```json
{
  "iss": "https://dev-12345678.okta.com/oauth2/default",
  "aud": "your-client-id",
  "sub": "00u1234567890abcdef",
  "email": "advisor.east@example.com",
  "groups": [
    "crdb_advisor_team_east",
    "crdb_developers"
  ],
  "exp": 1678901234,
  "iat": 1678897634
}
```

**Critical Checks**:
- `iss` matches `OKTA_ISSUER`
- `aud` matches `OKTA_AUDIENCE`
- `email` claim contains user email (used for `SET LOCAL role`)
- `groups` claim contains Okta security groups

### Example: HTTP Request with JWT

```bash
# Call application service through Istio ingress gateway
curl -H "Authorization: Bearer $JWT" \
     http://${INGRESS_HOST}/api/accounts

# Expected: 200 OK with response data
# Istio validates JWT and injects x-user-email, x-user-groups headers
# Application middleware reads headers and creates database connection with user context
```

### Example: JWT Validation Rejection

```bash
# Try without JWT token (should be rejected)
curl -v http://${INGRESS_HOST}/api/accounts

# Expected: HTTP 401 Unauthorized (Istio rejects - no JWT token)

# Try with invalid JWT token
curl -H "Authorization: Bearer invalid.jwt.token" \
     http://${INGRESS_HOST}/api/accounts

# Expected: HTTP 401 Unauthorized (Istio rejects - JWT validation failed)
```

## Request Flow with JWT

### Successful Flow (HTTP Request to Application Service)

```
1. Client → Istio Ingress Gateway
   HTTP Request: GET http://${INGRESS_HOST}/api/accounts
   Headers: Authorization: Bearer ${JWT}

2. Istio Ingress Gateway → RequestAuthentication (app-services namespace)
   - Fetches JWKS from Okta: ${OKTA_JWKS_URL}
   - Validates JWT signature using public keys
   - Verifies iss == ${OKTA_ISSUER}
   - Verifies aud == ${OKTA_AUDIENCE}
   - Extracts claims: email, groups
   - Injects headers:
     - x-user-email: advisor.east@example.com
     - x-user-groups: crdb_advisor_team_east,crdb_developers

3. Istio Ingress Gateway → AuthorizationPolicy (app-services namespace)
   - Checks: JWT validation succeeded?
   - Decision: ALLOW (JWT is valid)

4. Istio → VirtualService
   - Routes request to application service pod

5. VirtualService → Envoy Sidecar (on Application pod)
   - Forwards HTTP request with injected headers

6. Envoy Sidecar → Application Container
   - HTTP Request headers include:
     - x-user-email: advisor.east@example.com
     - x-user-groups: crdb_advisor_team_east,crdb_developers

7. Application Middleware → Database Connection
   - Reads x-user-email header
   - Creates database connection:
     conn = getConnection("pgbouncer-app:5432")
     BEGIN;
     SET LOCAL role = 'advisor.east@example.com';
     -- Execute queries (RLS policies applied)
     COMMIT;

8. Application → PgBouncer → CockroachDB
   - PostgreSQL wire protocol connection (no Istio involvement)
   - RLS policies filter rows based on SET LOCAL role
```

### Rejected Flow (No JWT)

```
1. Client → Istio Ingress Gateway
   HTTP Request: GET http://${INGRESS_HOST}/api/accounts
   Headers: (no Authorization header)

2. Istio Ingress Gateway → RequestAuthentication
   - No JWT token found
   - Validation result: NONE (no token)

3. Istio Ingress Gateway → AuthorizationPolicy
   - Checks: JWT validation succeeded?
   - Decision: DENY (requires valid JWT, but validation is NONE)

4. Istio → Client
   HTTP Response: 401 Unauthorized
   Body: "RBAC: access denied"
```

### Rejected Flow (Invalid JWT)

```
1. Client → Istio Ingress Gateway
   HTTP Request: GET http://${INGRESS_HOST}/api/accounts
   Headers: Authorization: Bearer ${INVALID_TOKEN}

2. Istio Ingress Gateway → RequestAuthentication
   - Fetches JWKS from Okta
   - Attempts to validate JWT signature
   - Validation fails: signature mismatch / expired / wrong issuer
   - Validation result: FAILED

3. Istio Ingress Gateway → AuthorizationPolicy
   - Checks: JWT validation succeeded?
   - Decision: DENY (JWT validation failed)

4. Istio → Client
   HTTP Response: 401 Unauthorized
   Body: "Jwt is not in the form of Header.Payload.Signature"
```

## Configuration Details

### RequestAuthentication Resource

```yaml
apiVersion: security.istio.io/v1beta1
kind: RequestAuthentication
metadata:
  name: jwt-auth-okta
  namespace: app-services
spec:
  jwtRules:
  - issuer: "${OKTA_ISSUER}"
    jwksUri: "${OKTA_JWKS_URL}"
    audiences:
    - "${OKTA_AUDIENCE}"
    forwardOriginalToken: true
    outputClaimToHeaders:
    - header: "x-user-email"
      claim: "email"
    - header: "x-user-groups"
      claim: "groups"
```

**Key Settings**:
- `namespace`: app-services (where application pods run)
- No selector: Applies to ALL pods in the namespace
- `issuer`: Must match `iss` claim in JWT
- `jwksUri`: Okta's public key endpoint for signature verification
- `audiences`: List of acceptable `aud` claims
- `forwardOriginalToken`: Keeps original JWT in Authorization header
- `outputClaimToHeaders`: Injects `x-user-email` and `x-user-groups` headers for application middleware

### AuthorizationPolicy Resource

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: require-jwt
  namespace: app-services
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        requestPrincipals: ["*"]
```

**Key Settings**:
- `namespace`: app-services
- No selector: Applies to ALL pods in the namespace
- `action: ALLOW`: Allow traffic that matches rules (implicit DENY for unmatched)
- `requestPrincipals: ["*"]`: Requires ANY valid JWT principal (i.e., JWT must validate)
- Effect: Blocks all traffic without valid JWT to app-services pods

### Gateway Resource (Optional - If Ingress Enabled)

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: app-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: app-gateway-cert
    hosts:
    - "*"
```

**Key Settings**:
- `namespace`: istio-system (gateway resources are cluster-scoped)
- `selector`: Uses Istio ingress gateway pods
- Ports: 80 (HTTP), 443 (HTTPS)
- Protocol: HTTP/HTTPS (for application services)
- TLS: Certificate stored in `app-gateway-cert` secret (create separately)

### VirtualService Resource (Example Template)

Application teams create VirtualService resources in their namespace to route traffic to their services:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: my-app-routes
  namespace: app-services
spec:
  hosts:
  - "*"  # Or specific domain: "api.example.com"
  gateways:
  - istio-system/app-gateway
  http:
  - match:
    - uri:
        prefix: "/api/"
    route:
    - destination:
        host: my-app-service  # Kubernetes service name
        port:
          number: 8080
```

**Key Settings**:
- `namespace`: app-services (where your application runs)
- `gateways`: References Gateway in istio-system namespace
- `http`: HTTP routing rules (path-based, header-based, etc.)
- `destination.host`: Kubernetes service name (short name within same namespace)

## Troubleshooting

### Istio Installation Issues

**Problem**: istiod pod not starting

```bash
# Check istiod logs
kubectl logs -n istio-system deployment/istiod

# Verify CRDs are installed
kubectl get crds | grep istio

# Reinstall if needed (use kubectl - istioctl has certificate issues)
kubectl delete namespace istio-system
kubectl delete crds -l app=istio
./setup.sh
```

**Problem**: Ingress gateway not getting external IP (stuck in Pending)

```bash
# Check service
kubectl get svc -n istio-system istio-ingressgateway

# Check events
kubectl describe svc -n istio-system istio-ingressgateway

# Verify AWS Load Balancer Controller is running
kubectl get pods -n kube-system | grep aws-load-balancer-controller

# Check AWS ELB console for provisioning status
aws elbv2 describe-load-balancers --region us-east-2 | \
    jq '.LoadBalancers[] | select(.LoadBalancerName | contains("istio"))'
```

### Sidecar Injection Issues

**Problem**: PgBouncer pods show 1/1 instead of 2/2 (no sidecar)

```bash
# Verify namespace label
kubectl get namespace cockroachdb -o jsonpath='{.metadata.labels.istio-injection}'
# Should return: enabled

# If not enabled:
kubectl label namespace cockroachdb istio-injection=enabled

# Restart PgBouncer pods to inject sidecars
kubectl rollout restart deployment/pgbouncer-app -n cockroachdb
kubectl rollout restart deployment/pgbouncer-batch -n cockroachdb
kubectl rollout restart deployment/pgbouncer-admin -n cockroachdb

# Verify sidecars were injected
kubectl get pods -n cockroachdb -l app.kubernetes.io/component=connection-pooler
```

### JWT Validation Issues

**Problem**: Connections rejected even with valid JWT

```bash
# Check RequestAuthentication configuration
kubectl get requestauthentication jwt-auth-okta -n cockroachdb -o yaml

# Verify JWKS URL is accessible from cluster
kubectl run -n istio-system curl-test --image=curlimages/curl:latest --rm -it -- \
    curl -v ${OKTA_JWKS_URL}

# Should return JSON with public keys

# Check Istio pilot logs for JWT errors
kubectl logs -n istio-system deployment/istiod | grep -i "jwt\|auth"

# Decode JWT and verify claims
echo $JWT_TOKEN | cut -d. -f2 | base64 -d | jq .
# Verify: iss, aud, groups are correct
```

**Problem**: JWKS fetch failures

```bash
# Istio cannot reach Okta JWKS endpoint
# Check if egress is blocked by NetworkPolicy

kubectl get networkpolicy -n istio-system
kubectl get networkpolicy -n cockroachdb

# May need to allow egress to Okta domain
# Add NetworkPolicy to allow istio-ingressgateway → Okta HTTPS (port 443)
```

### Connection Failures via Ingress

**Problem**: Cannot connect to ${INGRESS_HOST}:5432

```bash
# Check if ingress gateway is healthy
kubectl get pods -n istio-system -l app=istio-ingressgateway

# Check gateway configuration
kubectl get gateway -n cockroachdb pgbouncer-gateway -o yaml

# Check virtual service routes
kubectl get virtualservice -n cockroachdb pgbouncer-routes -o yaml

# Test from inside cluster (bypass ingress)
kubectl exec -n cockroachdb ${CRDB_CLUSTER_NAME_EAST}-0 -- \
    ./cockroach sql \
    --url "postgresql://root@pgbouncer-app:5432/defaultdb?sslmode=require" \
    --certs-dir=/cockroach/cockroach-certs \
    --execute="SELECT 1;"

# If above works, issue is with ingress gateway or NLB
```

**Problem**: NLB health checks failing

```bash
# Check NLB target group health
aws elbv2 describe-target-health \
    --target-group-arn <target-group-arn-from-aws-console>

# Verify health check port 15021 is accessible
kubectl port-forward -n istio-system svc/istio-ingressgateway 15021:15021 &
curl http://localhost:15021/healthz/ready
# Expected: HTTP 200 OK
```

## Monitoring

### Istio Metrics

```bash
# Check Istio proxy metrics on PgBouncer pod
kubectl exec -n cockroachdb <pgbouncer-app-pod> -c istio-proxy -- \
    curl -s http://localhost:15020/stats/prometheus | grep istio

# Key metrics:
# - istio_requests_total (total requests)
# - istio_request_duration_milliseconds (request latency)
# - istio_tcp_connections_opened_total (TCP connections)
# - istio_tcp_connections_closed_total (TCP connection closures)
```

### JWT Validation Metrics

```bash
# Watch logs for JWT validation and authentication failures
kubectl logs -n istio-system deployment/istio-ingressgateway --follow | grep -i -E 'jwt|auth'

# Check recent authentication errors
kubectl logs -n istio-system deployment/istio-ingressgateway --tail=100 | grep -i error
```

### Kiali Dashboard (Optional)

Deploy Kiali for Istio service mesh visualization:

```bash
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/addons/kiali.yaml

# Access Kiali dashboard (using kubectl port-forward - istioctl has certificate issues)
kubectl port-forward -n istio-system svc/kiali 20001:20001
# Then open: http://localhost:20001
```

## Teardown

```bash
cd ../..
./teardown.sh --phase 6
```

This will remove:
- Istio ingress gateway and services
- Istio control plane (istiod)
- RequestAuthentication and AuthorizationPolicy resources (from app-services namespace)
- Gateway and VirtualService resources
- Istio CRDs
- Sidecar injection label from app-services namespace

**Note**: This will restart application pods in app-services namespace to remove sidecars. PgBouncer pods are not affected (they never had sidecars).

## Next Steps

### Phase 7: Flyway Schema Migrations

Deploy Flyway for automated schema migrations:
- Copy SQL scripts from sample-data-pipeline repository
- Replace stub tables with full production schema
- Add comprehensive RLS policies
- Flyway connects via batch pool (bypasses PgBouncer transaction limits)

See [manifests/phase7-flyway/README.md](../phase7-flyway/README.md)

### Application Middleware Integration

Develop application middleware to:
1. **Read injected headers** (Istio already validated JWT and extracted claims):
   - `x-user-email`: User's email address (e.g., "advisor.east@example.com")
   - `x-user-groups`: Comma-separated list of Okta groups
2. **Create database connection** with user context:
   ```sql
   -- Pattern A: RLS Enforced (for user-facing queries)
   conn = getConnection("pgbouncer-app:5432")
   BEGIN;
   SET LOCAL role = 'advisor.east@example.com';  -- from x-user-email header
   -- Execute business queries (RLS policies applied)
   COMMIT;
   ```
3. **Propagate headers** to downstream microservice calls (Use Case 2A):
   - When calling other services, include `x-user-email` and `x-user-groups` headers
   - Downstream services repeat the same pattern (read headers → SET LOCAL role)

**Example Frameworks**:
- **Spring Boot (Java)**: RestTemplate interceptor + @Transactional hook
- **ASP.NET (C#)**: HttpClient middleware + EF Core interceptor
- **Flask (Python)**: before_request hook + SQLAlchemy event listener
- **Express (Node.js)**: Express middleware + database transaction wrapper

See [reference-implementations/](reference-implementations/) for complete examples.

## References

**Istio Documentation:**
- [JWT Authentication](https://istio.io/latest/docs/tasks/security/authentication/authn-policy/#end-user-authentication)
- [Authorization Policy](https://istio.io/latest/docs/reference/config/security/authorization-policy/)
- [Gateway Configuration](https://istio.io/latest/docs/reference/config/networking/gateway/)
- [VirtualService](https://istio.io/latest/docs/reference/config/networking/virtual-service/)

**Architecture Documentation:**
- [ARCHITECTURE.md](../../ARCHITECTURE.md) - Complete system architecture
- [CockroachDB Connectivity Guide](../../generated/references/0.4%20CockroachDB%20Connectivity%20Guide_%20User%20Access%20Design.pdf) - Identity propagation pattern

**Okta Documentation:**
- [Okta OAuth 2.0](https://developer.okta.com/docs/reference/api/oidc/)
- [JWKS Endpoint](https://developer.okta.com/docs/reference/api/oidc/#keys)
- [Custom Claims](https://developer.okta.com/docs/guides/customize-tokens-returned-from-okta/main/)
