#!/bin/bash
set -e

#######################################
# Phase 6: Istio Service Mesh Setup
#######################################
# Deploys Istio for JWT validation and user identity propagation
# Supports Use Case 1: End User via Application (RLS Enforced)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/config.env"
GENERATED_DIR="${ROOT_DIR}/generated/phase6"

mkdir -p "${GENERATED_DIR}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "\n${GREEN}===================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${GREEN}===================================${NC}\n"
}

print_info() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_step() {
    echo -e "${BLUE}▶${NC} $1"
}

load_config() {
    print_header "Loading Configuration"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Config file not found: ${CONFIG_FILE}"
        exit 1
    fi

    source "$CONFIG_FILE"

    # Required variables
    if [[ -z "$OKTA_ISSUER" ]]; then
        print_error "OKTA_ISSUER not set in config.env"
        exit 1
    fi

    if [[ -z "$OKTA_JWKS_URL" ]]; then
        print_error "OKTA_JWKS_URL not set in config.env"
        exit 1
    fi

    if [[ -z "$OKTA_AUDIENCE" ]]; then
        print_error "OKTA_AUDIENCE not set in config.env"
        exit 1
    fi

    # Optional with defaults
    APP_NAMESPACES="${APP_NAMESPACES:-app-services}"
    ENABLE_ISTIO_INGRESS="${ENABLE_ISTIO_INGRESS:-true}"
    ISTIO_VERSION="${ISTIO_VERSION:-1.20.2}"

    print_info "Okta Issuer: ${OKTA_ISSUER}"
    print_info "Okta JWKS URL: ${OKTA_JWKS_URL}"
    print_info "Okta Audience: ${OKTA_AUDIENCE}"
    print_info "Application Namespaces: ${APP_NAMESPACES}"
    print_info "Istio Ingress Gateway: ${ENABLE_ISTIO_INGRESS}"
}

check_prerequisites() {
    print_header "Checking Prerequisites"

    local missing=0

    # Check required tools
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed"
        missing=$((missing + 1))
    else
        print_info "kubectl is installed"
    fi

    # Check istioctl (required for generating manifests)
    if ! command -v istioctl &> /dev/null; then
        print_error "istioctl is not installed (required for generating manifests)"
        echo "Install with: brew install istioctl"
        missing=$((missing + 1))
    else
        print_info "istioctl is installed ($(istioctl version --short --remote=false 2>/dev/null || echo 'version check failed'))"
    fi

    if [ $missing -gt 0 ]; then
        print_error "Missing required tools"
        exit 1
    fi

    # Check kubectl connection with timeout
    print_step "Testing Kubernetes cluster connection..."
    if ! kubectl get nodes --request-timeout=10s &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster"
        print_error "Please check:"
        print_error "  1. kubectl config current-context"
        print_error "  2. aws eks update-kubeconfig --region ${AWS_REGION_EAST} --name ${CLUSTER_NAME_EAST}"
        print_error "  3. Network connectivity to EKS cluster"
        exit 1
    fi
    print_info "Connected to Kubernetes cluster"

    # Check if Phases 1-5 are complete
    if ! kubectl get namespace cockroachdb &> /dev/null; then
        print_error "cockroachdb namespace not found - run Phase 4 first"
        exit 1
    fi

    if ! kubectl get deployment -n cockroachdb pgbouncer-app &> /dev/null; then
        print_error "PgBouncer not deployed - run Phase 5 first"
        exit 1
    fi

    print_info "Prerequisites met (Phases 1-5 complete)"
}

install_istio() {
    print_header "Installing Istio Control Plane"

    # Check if Istio is already installed
    if kubectl get namespace istio-system &> /dev/null 2>&1; then
        print_warning "istio-system namespace already exists"

        if kubectl get deployment -n istio-system istiod &> /dev/null 2>&1; then
            print_warning "Istio control plane already deployed"

            read -p "Reinstall Istio? This will update the installation (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                print_info "Skipping Istio installation"
                return
            fi
        fi
    fi

    print_step "Installing Istio ${ISTIO_VERSION} with profile: default"

    # Determine profile based on ingress gateway setting
    if [[ "$ENABLE_ISTIO_INGRESS" == "true" ]]; then
        ISTIO_PROFILE="default"
        print_info "Installing with ingress gateway enabled"
    else
        ISTIO_PROFILE="minimal"
        print_info "Installing without ingress gateway (sidecar-only mode)"
    fi

    # Generate Istio manifests locally using istioctl
    # This is a local operation and doesn't require cluster connection
    MANIFEST_FILE="${GENERATED_DIR}/istio-${ISTIO_VERSION}-${ISTIO_PROFILE}.yaml"

    print_step "Generating Istio manifests locally..."

    if command -v istioctl &> /dev/null; then
        # Generate manifests locally (no cluster connection needed)
        istioctl manifest generate --set profile="${ISTIO_PROFILE}" > "${MANIFEST_FILE}" 2>/dev/null
        print_info "Manifests generated to ${MANIFEST_FILE}"
    else
        print_error "istioctl is required to generate manifests"
        print_error "Install with: brew install istioctl"
        exit 1
    fi

    # Create istio-system namespace if it doesn't exist
    if ! kubectl get namespace istio-system &> /dev/null; then
        print_step "Creating istio-system namespace..."
        kubectl create namespace istio-system
    fi

    # Apply manifests via kubectl
    print_step "Applying Istio manifests via kubectl..."
    kubectl apply -f "${MANIFEST_FILE}"

    # Wait for istiod to be ready
    print_step "Waiting for Istio control plane to be ready..."
    kubectl wait --for=condition=available --timeout=300s \
        deployment/istiod -n istio-system 2>/dev/null || true

    print_info "Istio control plane deployed successfully"
}

create_app_namespaces() {
    print_header "Creating Application Namespaces"

    # Convert comma-separated list to array
    IFS=',' read -ra NAMESPACES <<< "$APP_NAMESPACES"

    for ns in "${NAMESPACES[@]}"; do
        # Trim whitespace
        ns=$(echo "$ns" | xargs)

        if kubectl get namespace "$ns" &> /dev/null 2>&1; then
            print_warning "Namespace $ns already exists"
        else
            print_step "Creating namespace: $ns"
            kubectl create namespace "$ns"
        fi

        # Enable Istio sidecar injection
        print_step "Enabling Istio sidecar injection on namespace: $ns"
        kubectl label namespace "$ns" istio-injection=enabled --overwrite

        print_info "Namespace $ns configured for Istio"
    done
}

deploy_jwt_authentication() {
    print_header "Deploying JWT Authentication Resources"

    # Convert comma-separated list to array
    IFS=',' read -ra NAMESPACES <<< "$APP_NAMESPACES"

    for ns in "${NAMESPACES[@]}"; do
        ns=$(echo "$ns" | xargs)

        print_step "Creating RequestAuthentication in namespace: $ns"

        cat > "${GENERATED_DIR}/request-auth-${ns}.yaml" <<EOF
apiVersion: security.istio.io/v1beta1
kind: RequestAuthentication
metadata:
  name: jwt-auth-okta
  namespace: ${ns}
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
EOF

        kubectl apply -f "${GENERATED_DIR}/request-auth-${ns}.yaml"
        print_info "RequestAuthentication created in $ns"

        print_step "Creating AuthorizationPolicy in namespace: $ns"

        cat > "${GENERATED_DIR}/authz-policy-${ns}.yaml" <<EOF
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: require-jwt
  namespace: ${ns}
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        requestPrincipals: ["*"]  # Require valid JWT token
EOF

        kubectl apply -f "${GENERATED_DIR}/authz-policy-${ns}.yaml"
        print_info "AuthorizationPolicy created in $ns"
    done
}

configure_ingress_gateway() {
    if [[ "$ENABLE_ISTIO_INGRESS" != "true" ]]; then
        print_header "Istio Ingress Gateway"
        print_info "Ingress gateway disabled (sidecar-only mode)"
        return
    fi

    print_header "Configuring Istio Ingress Gateway"

    # Wait for ingress gateway to be ready
    print_step "Waiting for Istio ingress gateway to be ready..."
    kubectl wait --for=condition=available --timeout=300s \
        deployment/istio-ingressgateway -n istio-system || true

    # Create Gateway resource
    print_step "Creating Gateway resource for HTTP traffic"

    cat > "${GENERATED_DIR}/gateway.yaml" <<EOF
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
      credentialName: app-gateway-cert  # TLS certificate secret (create separately)
    hosts:
    - "*"
EOF

    kubectl apply -f "${GENERATED_DIR}/gateway.yaml"
    print_info "Gateway resource created"

    # Get external endpoint
    print_step "Retrieving ingress gateway external endpoint..."

    # Wait up to 2 minutes for external IP/hostname
    for i in {1..24}; do
        INGRESS_HOST=$(kubectl get svc -n istio-system istio-ingressgateway \
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

        if [[ -n "$INGRESS_HOST" ]]; then
            break
        fi

        if [[ $i -eq 1 ]]; then
            print_warning "Waiting for AWS NLB to provision (this may take 2-3 minutes)..."
        fi

        sleep 5
    done

    if [[ -z "$INGRESS_HOST" ]]; then
        print_warning "Ingress gateway external endpoint not ready yet"
        print_warning "Check later with: kubectl get svc -n istio-system istio-ingressgateway"
    else
        echo ""
        print_info "Ingress Gateway External Endpoint:"
        echo -e "${BLUE}  http://${INGRESS_HOST}${NC}"
        echo ""
        print_info "Test with:"
        echo -e "  ${BLUE}export JWT=\$(curl -X POST ${OKTA_ISSUER}/v1/token ...)${NC}"
        echo -e "  ${BLUE}curl -H \"Authorization: Bearer \$JWT\" http://${INGRESS_HOST}/api/accounts${NC}"
    fi
}

create_sample_virtualservice() {
    if [[ "$ENABLE_ISTIO_INGRESS" != "true" ]]; then
        return
    fi

    print_header "Creating Sample VirtualService"

    # This is a template - app teams will create their own VirtualServices
    # pointing to their specific services

    cat > "${GENERATED_DIR}/sample-virtualservice.yaml" <<EOF
# Example VirtualService - Copy and modify for your application
# This routes HTTP traffic from the ingress gateway to your application service
#
# Usage:
#   1. Replace 'my-app-service' with your actual service name
#   2. Update namespace to match your app
#   3. Configure routing rules for your API paths
#   4. Apply: kubectl apply -f virtualservice.yaml

apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: my-app-routes
  namespace: app-services  # Change to your namespace
spec:
  hosts:
  - "*"  # Or specific hostname: "api.example.com"
  gateways:
  - istio-system/app-gateway
  http:
  - match:
    - uri:
        prefix: "/api/"
    route:
    - destination:
        host: my-app-service  # Your Kubernetes service name
        port:
          number: 8080  # Your service port
EOF

    print_info "Sample VirtualService template created at:"
    echo "  ${GENERATED_DIR}/sample-virtualservice.yaml"
    print_warning "App teams should customize this for their services"
}

display_summary() {
    print_header "Phase 6 Installation Complete"

    echo -e "${GREEN}✓ Istio Components:${NC}"
    echo "  - Control plane (istiod) deployed in istio-system namespace"

    if [[ "$ENABLE_ISTIO_INGRESS" == "true" ]]; then
        echo "  - Ingress gateway deployed with AWS NLB"
    else
        echo "  - Sidecar-only mode (no ingress gateway)"
    fi

    echo ""
    echo -e "${GREEN}✓ Application Namespaces with Istio Injection:${NC}"
    IFS=',' read -ra NAMESPACES <<< "$APP_NAMESPACES"
    for ns in "${NAMESPACES[@]}"; do
        ns=$(echo "$ns" | xargs)
        echo "  - ${ns}"
    done

    echo ""
    echo -e "${GREEN}✓ JWT Authentication:${NC}"
    echo "  - Issuer: ${OKTA_ISSUER}"
    echo "  - JWKS URL: ${OKTA_JWKS_URL}"
    echo "  - Audience: ${OKTA_AUDIENCE}"
    echo "  - Headers: x-user-email, x-user-groups"

    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo ""
    echo "1. Verify Istio installation:"
    echo "   ${BLUE}kubectl get deployment -n istio-system istiod -o jsonpath='{.spec.template.spec.containers[0].image}{\"\\n\"}'${NC}"
    echo "   ${BLUE}kubectl get pods -n istio-system${NC}"
    echo ""
    echo "2. Deploy application with sidecar injection:"
    echo "   ${BLUE}kubectl apply -f your-app.yaml -n app-services${NC}"
    echo "   Verify pods show 2/2 READY (app container + sidecar)"
    echo ""
    echo "3. Integrate middleware (see reference implementations):"
    echo "   ${BLUE}ls -la ${SCRIPT_DIR}/reference-implementations/${NC}"
    echo ""
    echo "4. Test JWT validation:"
    echo "   See: ${BLUE}${SCRIPT_DIR}/TESTING.md${NC}"
    echo ""

    if [[ "$ENABLE_ISTIO_INGRESS" == "true" ]]; then
        echo "5. Create VirtualService for your app:"
        echo "   ${BLUE}cp ${GENERATED_DIR}/sample-virtualservice.yaml my-app-vs.yaml${NC}"
        echo "   Edit and apply to route traffic to your service"
        echo ""
    fi

    echo -e "${GREEN}Documentation:${NC}"
    echo "  - Implementation Plan: ${SCRIPT_DIR}/IMPLEMENTATION_PLAN.md"
    echo "  - Use Case Mapping: ${SCRIPT_DIR}/USE_CASE_MAPPING.md"
    echo "  - Developer Guide (Production): ${SCRIPT_DIR}/DEVELOPER_GUIDE_PRODUCTION.md"
    echo "  - Developer Guide (Local Dev): ${SCRIPT_DIR}/DEVELOPER_GUIDE_LOCAL.md"
    echo ""
    echo -e "${GREEN}✓ Phase 6 Complete!${NC}"
    echo ""
}

# Main execution
main() {
    print_header "Phase 6: Istio Service Mesh Setup"

    load_config
    check_prerequisites
    install_istio
    create_app_namespaces
    deploy_jwt_authentication

    if [[ "$ENABLE_ISTIO_INGRESS" == "true" ]]; then
        configure_ingress_gateway
        create_sample_virtualservice
    fi

    display_summary
}

main "$@"
