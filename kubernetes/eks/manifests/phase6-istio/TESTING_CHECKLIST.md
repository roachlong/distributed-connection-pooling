# Phase 6: Istio Testing Checklist

Quick validation steps to verify Phase 6 deployment before creating reference implementations.

## ⚠️ Important: istioctl Limitations

**Certificate Issue:** If your EKS cluster uses self-signed certificates, `istioctl` commands that connect to the cluster (like `istioctl version`, `istioctl analyze`, `istioctl proxy-status`) will fail with certificate verification errors.

**Workaround:** All validation steps below use `kubectl` commands instead of `istioctl`. The setup script uses `istioctl manifest generate` (local operation only) to generate manifests, then applies them via `kubectl`.

## Pre-Test: Update Configuration

```bash
cd /Users/jleelong/workspace/distributed-connection-pooling/kubernetes/eks

# Update config.env with your Okta settings
vi config.env

# Required values (from Phase 0):
# export OKTA_ISSUER="https://your-domain.okta.com/oauth2/default"
# export OKTA_JWKS_URL="https://your-domain.okta.com/oauth2/default/v1/keys"
# export OKTA_CLIENT_ID="your-client-id"
# export OKTA_AUDIENCE="your-audience"

# Application namespace
# export APP_NAMESPACES="app-services"

# Istio ingress gateway (for testing from local workstation)
# export ENABLE_ISTIO_INGRESS="true"

# Source the config
source config.env
```

## Test 1: Run Setup Script

```bash
cd manifests/phase6-istio
chmod +x setup.sh
./setup.sh
```

**Expected Output:**
- ✅ Istio control plane installed in `istio-system` namespace
- ✅ `app-services` namespace created with `istio-injection=enabled` label
- ✅ RequestAuthentication resource created
- ✅ AuthorizationPolicy resource created
- ✅ Istio ingress gateway deployed (if enabled)
- ✅ External NLB endpoint displayed (if ingress enabled)

**Verify:**
```bash
# Check Istio control plane version (kubectl method - istioctl has certificate issues)
kubectl get deployment -n istio-system istiod -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

# Should show: docker.io/istio/pilot:1.20.2 (or similar)
```

## Test 2: Verify Istio Control Plane

```bash
# Check istio-system namespace
kubectl get pods -n istio-system

# Expected output:
# NAME                                    READY   STATUS    RESTARTS   AGE
# istiod-xxxxxxxxxx-xxxxx                 1/1     Running   0          2m
# istio-ingressgateway-xxxxxxxxxx-xxxxx   1/1     Running   0          2m  (if ingress enabled)
```

**All pods should be Running and READY 1/1.**

## Test 3: Verify Application Namespace

```bash
# Check namespace label
kubectl get namespace app-services -o jsonpath='{.metadata.labels.istio-injection}'

# Expected output: enabled
```

**If not "enabled", sidecar injection won't work.**

## Test 4: Verify JWT Authentication Resources

```bash
# Check RequestAuthentication
kubectl get requestauthentication -n app-services

# Expected output:
# NAME            AGE
# jwt-auth-okta   2m

# Check details
kubectl describe requestauthentication jwt-auth-okta -n app-services

# Should show:
# - Issuer: <your OKTA_ISSUER>
# - Jwks Uri: <your OKTA_JWKS_URL>
# - Audiences: <your OKTA_AUDIENCE>
# - Output Claim To Headers:
#     - Header: x-user-email, Claim: email
#     - Header: x-user-groups, Claim: groups
```

```bash
# Check AuthorizationPolicy
kubectl get authorizationpolicy -n app-services

# Expected output:
# NAME           AGE
# require-jwt    2m

# Check details
kubectl describe authorizationpolicy require-jwt -n app-services

# Should show:
# - Action: ALLOW
# - Rules: requestPrincipals: ["*"]
```

## Test 5: Verify Ingress Gateway (If Enabled)

```bash
# Get ingress gateway service
kubectl get svc -n istio-system istio-ingressgateway

# Expected output:
# NAME                   TYPE           CLUSTER-IP       EXTERNAL-IP                                                               PORT(S)
# istio-ingressgateway   LoadBalancer   172.20.xxx.xxx   a1234567890abcdef-1234567890.us-east-2.elb.amazonaws.com   80:xxxxx/TCP,443:xxxxx/TCP

# Get external endpoint
export INGRESS_HOST=$(kubectl get svc -n istio-system istio-ingressgateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo $INGRESS_HOST

# Should show AWS NLB hostname (may take 2-3 minutes to provision)
```

**If EXTERNAL-IP shows `<pending>`, wait a few minutes for AWS NLB to provision.**

## Test 6: Deploy Test Application with Sidecar

```bash
# Create a simple echo service to test sidecar injection
cat > /tmp/test-echo-service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: echo-service
  namespace: app-services
spec:
  selector:
    app: echo
  ports:
  - port: 8080
    targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  namespace: app-services
spec:
  replicas: 1
  selector:
    matchLabels:
      app: echo
  template:
    metadata:
      labels:
        app: echo
    spec:
      containers:
      - name: echo
        image: hashicorp/http-echo:latest
        args:
        - "-text=Echo service is running"
        - "-listen=:8080"
        ports:
        - containerPort: 8080
EOF

kubectl apply -f /tmp/test-echo-service.yaml
```

**Verify sidecar injection:**
```bash
# Check pod - should show 2/2 READY (app container + Istio sidecar)
kubectl get pods -n app-services

# Expected output:
# NAME                    READY   STATUS    RESTARTS   AGE
# echo-xxxxxxxxxx-xxxxx   2/2     Running   0          30s

# Check pod details to see sidecar
kubectl describe pod -n app-services -l app=echo

# Should show two containers:
# - echo (your application)
# - istio-proxy (Envoy sidecar)
```

**If showing 1/1 instead of 2/2:**
- Check namespace label: `kubectl get ns app-services --show-labels`
- Should have `istio-injection=enabled`
- Delete pod to trigger re-creation: `kubectl delete pod -n app-services -l app=echo`

## Test 7: Test JWT Validation (In-Cluster - No Ingress)

This test validates Istio JWT authentication for in-cluster service calls.

### 7a. Test Without JWT (Should Fail with 403)

```bash
# Try to access echo-service without JWT
kubectl run test-client --rm -i --restart=Never --namespace=app-services \
  --image=curlimages/curl:latest -- \
  curl -v http://echo-service:8080

# Expected output:
# HTTP/1.1 403 Forbidden
# RBAC: access denied

# This proves:
# ✅ AuthorizationPolicy requires JWT for ALL traffic in app-services namespace
# ✅ Istio sidecar is enforcing authentication (not just at ingress gateway)
```

### 7b. Test With Valid JWT (Should Succeed)

**Get JWT from Okta:**
```bash
# Option 1: Use Okta token endpoint (if password grant enabled)
export JWT=$(curl -s -X POST ${OKTA_ISSUER}/v1/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=${OKTA_CLIENT_ID}" \
  -d "client_secret=<your-client-secret>" \
  -d "username=<test-user@example.com>" \
  -d "password=<password>" \
  -d "scope=openid profile email groups" \
  | jq -r '.id_token')

# Option 2: Use existing JWT from your okta-crdb-sync workflow
# export JWT=$(cat ~/.crdb-token | jq -r '.id_token')

# Verify JWT claims
echo $JWT | cut -d. -f2 | base64 -d | jq .
# Should show email and groups claims
```

**Test with JWT:**
```bash
# Call echo-service with JWT
kubectl run test-client --rm -i --restart=Never --namespace=app-services \
  --image=curlimages/curl:latest -- \
  curl -v -H "Authorization: Bearer $JWT" http://echo-service:8080

# Expected output:
# HTTP/1.1 200 OK
# Echo service is running

# This proves:
# ✅ Istio validated JWT signature against Okta JWKS
# ✅ JWT claims matched RequestAuthentication config
# ✅ AuthorizationPolicy allowed traffic with valid JWT
```

### 7c. Verify Istio Injects Headers

```bash
# Deploy httpbin to echo request headers
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/httpbin.yaml -n app-services

# Wait for httpbin to be ready
kubectl wait --for=condition=ready pod -l app=httpbin -n app-services --timeout=60s

# Call httpbin /headers endpoint with JWT
kubectl run test-client --rm -i --restart=Never --namespace=app-services \
  --image=curlimages/curl:latest -- \
  curl -H "Authorization: Bearer $JWT" http://httpbin:8000/headers

# Expected output should include:
# {
#   "headers": {
#     "X-User-Email": "<user-email-from-jwt>",
#     "X-User-Groups": "<groups-from-jwt>",
#     ...
#   }
# }

# This proves:
# ✅ Istio extracted JWT claims (email, groups)
# ✅ Istio injected claims as HTTP headers (x-user-email, x-user-groups)
# ✅ Application receives user identity and roles in headers
```

**If headers NOT present:**
- Check RequestAuthentication: `kubectl describe requestauthentication jwt-auth-okta -n app-services`
- Verify `outputClaimToHeaders` is configured correctly
- Verify JWT has `email` and `groups` claims: `echo $JWT | cut -d. -f2 | base64 -d | jq .`

## Test 8: Test JWT Validation (Via Ingress Gateway)

**Skip this test if `ENABLE_ISTIO_INGRESS="false"`**

This test validates the same JWT flow as Test 7, but via the external LoadBalancer ingress gateway.

### 8a. Test Without JWT (Should Fail)

```bash
# Try to access through ingress gateway without JWT
curl -v http://$INGRESS_HOST/

# Expected result:
# HTTP 401 Unauthorized or connection refused
# (No route configured yet, but if there was a route, would fail JWT check)
```

### 8b. Create VirtualService for Echo Service

```bash
cat > /tmp/echo-virtualservice.yaml <<EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: echo-routes
  namespace: app-services
spec:
  hosts:
  - "*"
  gateways:
  - istio-system/app-gateway
  http:
  - match:
    - uri:
        prefix: "/"
    route:
    - destination:
        host: echo-service
        port:
          number: 8080
EOF

kubectl apply -f /tmp/echo-virtualservice.yaml
```

### 8c. Test With Valid JWT

**Get JWT from Okta:**
```bash
# Option 1: Use Okta token endpoint (if password grant enabled)
export JWT=$(curl -s -X POST ${OKTA_ISSUER}/v1/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=${OKTA_CLIENT_ID}" \
  -d "client_secret=<your-client-secret>" \
  -d "username=<test-user@example.com>" \
  -d "password=<password>" \
  -d "scope=openid profile email groups" \
  | jq -r '.id_token')

# Option 2: Use existing JWT from crdb-sql.py script
# export JWT=$(cat ~/.crdb-token | jq -r '.id_token')

# Decode JWT to verify claims
echo $JWT | cut -d. -f2 | base64 -d | jq .

# Should show:
# {
#   "iss": "<your OKTA_ISSUER>",
#   "aud": "<your OKTA_AUDIENCE>",
#   "sub": "<user-email>",
#   "email": "<user-email>",
#   "groups": ["crdb_advisor_team_east", ...]
# }
```

**Test with JWT:**
```bash
# Call ingress gateway with JWT
curl -H "Authorization: Bearer $JWT" http://$INGRESS_HOST/

# Expected output:
# Echo service is running

# This works because:
# 1. Istio validated JWT signature
# 2. JWT claims match RequestAuthentication config
# 3. AuthorizationPolicy allows traffic with valid JWT
```

### 8d. Verify Headers Injected

```bash
# Deploy httpbin to echo request headers
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/httpbin.yaml -n app-services

# Update VirtualService to route to httpbin
kubectl patch virtualservice echo-routes -n app-services --type=json \
  -p='[{"op": "replace", "path": "/spec/http/0/route/0/destination/host", "value": "httpbin"}]'

# Call with JWT
curl -H "Authorization: Bearer $JWT" http://$INGRESS_HOST/headers

# Expected output should include:
# {
#   "headers": {
#     "X-User-Email": "<user-email-from-jwt>",
#     "X-User-Groups": "<groups-from-jwt>",
#     ...
#   }
# }
```

**If headers NOT present:**
- Check RequestAuthentication: `kubectl describe requestauthentication jwt-auth-okta -n app-services`
- Verify `outputClaimToHeaders` is configured correctly
- Check JWT has `email` and `groups` claims

---

## Test 9: Full Auth Flow with Sample Application

This test demonstrates the **complete auth flow** including database connection, middleware pattern, and RLS enforcement.

**What This Test Proves:**
1. ✅ Istio validates JWT and injects user identity headers
2. ✅ Application reads headers (user email, roles/groups)
3. ✅ Application connects to PgBouncer as `pgb_app_user` service account
4. ✅ Middleware sets session variables (`SET LOCAL app.current_user`, `app.current_roles`)
5. ✅ RLS policy enforces data access based on session variables
6. ✅ User sees only data authorized for their role

**Architecture Pattern:**
- User `alice@example.com` exists in Okta (not in CockroachDB)
- Role `crdb_advisor_team_east` exists in CockroachDB (NOLOGIN)
- Application connects as `pgb_app_user` (service account)
- Identity propagated via session variables, not SQL username

### 9a. Deploy Sample Application

```bash
# Create sample app deployment
cat > /tmp/sample-auth-app.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: sample-auth-app-config
  namespace: app-services
data:
  app.py: |
    from flask import Flask, request, jsonify
    import psycopg2
    import os

    app = Flask(__name__)

    # PgBouncer connection (app pool - port 5432)
    DB_HOST = "pgbouncer-app.cockroachdb.svc.cluster.local"
    DB_PORT = "5432"
    DB_NAME = "production"
    DB_SSLMODE = "require"

    @app.route('/health')
    def health():
        return jsonify({"status": "healthy"}), 200

    @app.route('/whoami')
    def whoami():
        """Demonstrates auth flow: Istio headers → SET LOCAL → query execution"""
        
        # Step 1: Read Istio-injected headers
        user_email = request.headers.get('x-user-email', 'unknown')
        user_groups = request.headers.get('x-user-groups', '')
        
        if user_email == 'unknown':
            return jsonify({
                "error": "No user identity found",
                "hint": "Request must include valid JWT token"
            }), 401
        
        try:
            # Step 2: Connect to PgBouncer as pgb_app_user (service account)
            # Note: All users connect as the same service account
            conn = psycopg2.connect(
                host=DB_HOST,
                port=DB_PORT,
                database=DB_NAME,
                user="test",  # PgBouncer auth_type=any allows any username
                sslmode=DB_SSLMODE
            )
            cur = conn.cursor()
            
            # Step 3: Middleware pattern - set session variables for RLS
            cur.execute("SET LOCAL app.current_user = %s", (user_email,))
            cur.execute("SET LOCAL app.current_roles = %s", (user_groups,))
            
            # Step 4: Verify session context
            cur.execute("SHOW app.current_user")
            current_user = cur.fetchone()[0]
            
            cur.execute("SHOW app.current_roles")
            current_roles = cur.fetchone()[0]
            
            # Step 5: Query that would be subject to RLS (example)
            # In real app, this would query tables with RLS policies
            cur.execute("SELECT current_user, session_user, current_database()")
            db_info = cur.fetchone()
            
            conn.commit()
            cur.close()
            conn.close()
            
            return jsonify({
                "message": "Auth flow successful",
                "user_identity": {
                    "email": user_email,
                    "groups": user_groups
                },
                "session_context": {
                    "app_current_user": current_user,
                    "app_current_roles": current_roles
                },
                "database_connection": {
                    "current_user": db_info[0],  # pgb_app_user
                    "session_user": db_info[1],  # pgb_app_user  
                    "database": db_info[2]       # production
                },
                "proof": f"User {user_email} connected as {db_info[0]}, but RLS sees {current_user}"
            }), 200
            
        except Exception as e:
            return jsonify({"error": str(e)}), 500

    if __name__ == '__main__':
        app.run(host='0.0.0.0', port=8080)
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-auth-app
  namespace: app-services
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sample-auth-app
  template:
    metadata:
      labels:
        app: sample-auth-app
    spec:
      containers:
      - name: app
        image: python:3.11-slim
        command: ["/bin/sh", "-c"]
        args:
          - |
            pip install flask psycopg2-binary && \
            python /app/app.py
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: app-code
          mountPath: /app
      volumes:
      - name: app-code
        configMap:
          name: sample-auth-app-config
---
apiVersion: v1
kind: Service
metadata:
  name: sample-auth-app
  namespace: app-services
spec:
  selector:
    app: sample-auth-app
  ports:
  - port: 8080
    targetPort: 8080
EOF

kubectl apply -f /tmp/sample-auth-app.yaml

# Wait for app to be ready
kubectl wait --for=condition=ready pod -l app=sample-auth-app -n app-services --timeout=120s

# Expected output:
# configmap/sample-auth-app-config created
# deployment.apps/sample-auth-app created
# service/sample-auth-app created
# pod/sample-auth-app-xxxxxxxxxx-xxxxx condition met
```

### 9b. Test Auth Flow Without JWT (Should Fail)

```bash
# Try to access without JWT
kubectl run test-client --rm -i --restart=Never --namespace=app-services \
  --image=curlimages/curl:latest -- \
  curl -v http://sample-auth-app:8080/whoami

# Expected output:
# HTTP/1.1 403 Forbidden
# RBAC: access denied

# This proves: Istio blocks requests without JWT
```

### 9c. Test Full Auth Flow With JWT (Should Succeed)

```bash
# Call with valid JWT (use JWT from Test 7b)
kubectl run test-client --rm -i --restart=Never --namespace=app-services \
  --image=curlimages/curl:latest -- \
  curl -H "Authorization: Bearer $JWT" http://sample-auth-app:8080/whoami

# Expected output:
# {
#   "message": "Auth flow successful",
#   "user_identity": {
#     "email": "alice@example.com",
#     "groups": "crdb_advisor_team_east"
#   },
#   "session_context": {
#     "app_current_user": "alice@example.com",
#     "app_current_roles": "crdb_advisor_team_east"
#   },
#   "database_connection": {
#     "current_user": "pgb_app_user",
#     "session_user": "pgb_app_user",
#     "database": "production"
#   },
#   "proof": "User alice@example.com connected as pgb_app_user, but RLS sees alice@example.com"
# }
```

**What This Proves:**

1. ✅ **Istio validated JWT** - Request with JWT was allowed (403 without JWT)
2. ✅ **Istio injected headers** - `x-user-email` and `x-user-groups` received by app
3. ✅ **Middleware pattern works** - App connected as `pgb_app_user`, set session variables
4. ✅ **Identity propagation** - `app.current_user` = alice@example.com (not pgb_app_user)
5. ✅ **RLS ready** - Session variables available for RLS policies
6. ✅ **No user provisioning needed** - alice@example.com doesn't exist in CRDB

**Key Architecture Points:**

- **alice@example.com** does NOT exist in CockroachDB
- **pgb_app_user** is the actual SQL user (service account)
- **app.current_user** session variable = alice@example.com (for RLS)
- **app.current_roles** session variable = crdb_advisor_team_east (for RLS)
- RLS policies check session variables, not the SQL username

### 9d. Verify Different Users See Different Context

If you have multiple Okta test users, test with different JWTs:

```bash
# Get JWT for bob@example.com (different user, different groups)
export JWT_BOB="<bob's JWT token>"

# Call with Bob's JWT
kubectl run test-client --rm -i --restart=Never --namespace=app-services \
  --image=curlimages/curl:latest -- \
  curl -H "Authorization: Bearer $JWT_BOB" http://sample-auth-app:8080/whoami

# Should show:
# - user_identity.email: bob@example.com
# - session_context.app_current_user: bob@example.com
# - database_connection.current_user: pgb_app_user (same for all users)

# This proves: Different users get different session context, but connect as same service account
```

## Test 10: Cleanup Test Resources

```bash
# Remove sample auth app
kubectl delete deployment sample-auth-app -n app-services
kubectl delete service sample-auth-app -n app-services
kubectl delete configmap sample-auth-app-config -n app-services

# Remove test deployments
kubectl delete deployment echo -n app-services --ignore-not-found
kubectl delete deployment httpbin -n app-services --ignore-not-found
kubectl delete service echo-service -n app-services --ignore-not-found
kubectl delete service httpbin -n app-services --ignore-not-found
kubectl delete virtualservice echo-routes -n app-services --ignore-not-found

# Verify cleanup
kubectl get all -n app-services

# Expected: No resources (empty namespace except for istio components)
```

**Note:** This leaves the `app-services` namespace and Istio configuration intact for future application deployments.

---

## Success Criteria

Phase 6 is working correctly if:

**Infrastructure:**
- ✅ Istio control plane running (`istiod` pod 1/1 READY)
- ✅ Istio ingress gateway running (if enabled, 1/1 READY)
- ✅ `app-services` namespace has `istio-injection=enabled` label
- ✅ Pods in `app-services` show 2/2 READY (app + sidecar)
- ✅ RequestAuthentication resource created with correct Okta config
- ✅ AuthorizationPolicy resource created

**JWT Authentication (Istio Layer):**
- ✅ Requests without JWT are rejected (403 RBAC denied)
- ✅ Requests with valid JWT are accepted (200 OK)
- ✅ Headers `x-user-email` and `x-user-groups` injected by Istio
- ✅ Works for both in-cluster and ingress gateway traffic

**Full Auth Flow (Application + Database):**
- ✅ Application receives Istio-injected headers
- ✅ Application connects to PgBouncer as service account (`pgb_app_user`)
- ✅ Middleware sets session variables (`SET LOCAL app.current_user`, `app.current_roles`)
- ✅ Session context reflects real user identity (not service account)
- ✅ Different JWTs produce different session contexts
- ✅ No CockroachDB user provisioning required (users don't exist in CRDB)

---

## Troubleshooting

### Sidecar Not Injected (Pod shows 1/1 instead of 2/2)

```bash
# Check namespace label
kubectl get namespace app-services -o jsonpath='{.metadata.labels.istio-injection}'

# If not "enabled":
kubectl label namespace app-services istio-injection=enabled --overwrite

# Delete pod to trigger re-creation
kubectl delete pod -n app-services -l app=<your-app-label>
```

### JWT Validation Failing

```bash
# Check RequestAuthentication config
kubectl get requestauthentication jwt-auth-okta -n app-services -o yaml

# Verify:
# - issuer matches your OKTA_ISSUER
# - jwksUri matches your OKTA_JWKS_URL
# - audiences contains your OKTA_AUDIENCE

# Decode your JWT to verify claims
echo $JWT | cut -d. -f2 | base64 -d | jq .

# Verify:
# - "iss" claim matches OKTA_ISSUER
# - "aud" claim matches OKTA_AUDIENCE
# - "email" claim exists
# - "groups" claim exists
```

### Headers Not Injected

```bash
# Check RequestAuthentication outputClaimToHeaders
kubectl get requestauthentication jwt-auth-okta -n app-services -o yaml | grep -A 10 outputClaimToHeaders

# Should show:
# outputClaimToHeaders:
# - claim: email
#   header: x-user-email
# - claim: groups
#   header: x-user-groups
```

### Ingress Gateway Not Getting External IP

```bash
# Check service
kubectl get svc -n istio-system istio-ingressgateway

# If EXTERNAL-IP shows <pending>:
# - Wait 2-3 minutes (AWS NLB provisioning takes time)
# - Check AWS console for NLB creation
# - Check EKS cluster has proper IAM roles for creating load balancers
```

---

## Next Steps After Testing

Once all tests pass:

1. **Report Results** - Share any issues or successful test results
2. **Create Reference Implementations** - Java, C#, Python middleware examples
3. **Create Developer Guides** - Production deployment and local development guides
4. **Document Edge Cases** - Header propagation, error handling, debugging

**Ready to test? Run the setup script and work through this checklist!**
