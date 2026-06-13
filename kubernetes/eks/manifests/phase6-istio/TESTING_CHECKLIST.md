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

## Test 7: Test Internal Service Call (No JWT Required)

```bash
# Create a test pod in the same namespace
kubectl run test-client --rm -i --restart=Never --namespace=app-services \
  --image=curlimages/curl:latest -- \
  curl -v http://echo-service:8080

# Expected output:
# Echo service is running

# This works because:
# 1. Internal service-to-service call (mTLS only)
# 2. AuthorizationPolicy only applies to ingress gateway traffic
# 3. No JWT required for in-cluster calls
```

## Test 8: Test JWT Validation (If Ingress Enabled)

**Skip this test if `ENABLE_ISTIO_INGRESS="false"`**

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

## Test 9: Cleanup Test Resources

```bash
# Remove test deployments
kubectl delete deployment echo -n app-services
kubectl delete deployment httpbin -n app-services
kubectl delete service echo-service -n app-services
kubectl delete service httpbin -n app-services
kubectl delete virtualservice echo-routes -n app-services
```

---

## Success Criteria

Phase 6 is working correctly if:

- ✅ Istio control plane running (`istiod` pod 1/1 READY)
- ✅ Istio ingress gateway running (if enabled, 1/1 READY)
- ✅ `app-services` namespace has `istio-injection=enabled` label
- ✅ Pods in `app-services` show 2/2 READY (app + sidecar)
- ✅ RequestAuthentication resource created with correct Okta config
- ✅ AuthorizationPolicy resource created
- ✅ Internal service calls work without JWT (mTLS only)
- ✅ Ingress gateway rejects requests without JWT (if testing with ingress)
- ✅ Ingress gateway accepts requests with valid JWT (if testing with ingress)
- ✅ Headers `x-user-email` and `x-user-groups` injected correctly

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
