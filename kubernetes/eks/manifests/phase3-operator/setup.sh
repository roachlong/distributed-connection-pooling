#!/bin/bash
set -e

#######################################
# Phase 3: CockroachDB Operator Setup
#######################################
# Deploys the CockroachDB Kubernetes Operator

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/config.env"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
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

check_prerequisites() {
    print_header "Checking Prerequisites"

    local missing=0

    # Check required tools
    for tool in kubectl helm; do
        if ! command -v $tool &> /dev/null; then
            print_error "$tool is not installed"
            missing=$((missing + 1))
        else
            print_info "$tool is installed ($(command -v $tool))"
        fi
    done

    if [ $missing -gt 0 ]; then
        print_error "Missing required tools. Please install them first."
        exit 1
    fi

    # Check kubectl can connect to cluster
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster"
        print_error "Run: aws eks update-kubeconfig --name \${CLUSTER_NAME_EAST} --region \${AWS_REGION_EAST} --profile \${AWS_PROFILE}"
        exit 1
    fi

    print_info "All prerequisites met"
}

load_config() {
    print_header "Loading Configuration"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Config file not found: ${CONFIG_FILE}"
        exit 1
    fi

    source "$CONFIG_FILE"

    print_info "Configuration loaded from ${CONFIG_FILE}"
    print_info "  Cluster: ${CLUSTER_NAME_EAST}"
    print_info "  Operator Version: ${COCKROACHDB_OPERATOR_VERSION}"
    print_info "  Namespace: ${CRDB_NAMESPACE}"
}

install_operator() {
    print_header "Installing CockroachDB Operator"

    # Check for existing Helm installation and clean it up
    if helm list -n cockroach-operator-system 2>/dev/null | grep -q cockroachdb-operator; then
        print_warning "Found Helm-based operator installation, cleaning up..."
        helm uninstall cockroachdb-operator -n cockroach-operator-system || true
        print_info "Helm installation removed"
    fi

    # Check if operator deployment already exists and is healthy
    if kubectl get deployment cockroach-operator-manager -n cockroach-operator-system &>/dev/null; then
        # Check if deployment is actually ready
        READY=$(kubectl get deployment cockroach-operator-manager -n cockroach-operator-system -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")

        if [[ "$READY" == "True" ]]; then
            print_warning "CockroachDB Operator already installed and healthy"
            return 0
        else
            print_warning "Found unhealthy operator deployment, cleaning up..."
            kubectl delete namespace cockroach-operator-system --wait=false 2>/dev/null || true
            sleep 5
            print_info "Waiting for namespace deletion..."
            kubectl wait --for=delete namespace/cockroach-operator-system --timeout=60s 2>/dev/null || true
        fi
    fi

    # Ensure namespace exists
    if ! kubectl get namespace cockroach-operator-system &>/dev/null; then
        print_info "Creating cockroach-operator-system namespace..."
        kubectl create namespace cockroach-operator-system
    fi

    # Construct URLs for operator manifests
    local CRD_URL="https://raw.githubusercontent.com/cockroachdb/cockroach-operator/${COCKROACHDB_OPERATOR_VERSION}/install/crds.yaml"
    local OPERATOR_URL="https://raw.githubusercontent.com/cockroachdb/cockroach-operator/${COCKROACHDB_OPERATOR_VERSION}/install/operator.yaml"

    # Install CRDs (kubectl will fail with clear error if version doesn't exist)
    print_info "Installing CockroachDB Operator CRDs (${COCKROACHDB_OPERATOR_VERSION})..."
    if ! kubectl apply -f "${CRD_URL}"; then
        print_error "Failed to install CRDs"
        print_error "Check that version ${COCKROACHDB_OPERATOR_VERSION} exists at:"
        print_error "  https://github.com/cockroachdb/cockroach-operator/tags"
        exit 1
    fi

    # Install Operator
    print_info "Installing CockroachDB Operator ${COCKROACHDB_OPERATOR_VERSION}..."
    if ! kubectl apply -f "${OPERATOR_URL}"; then
        print_error "Failed to install operator"
        exit 1
    fi

    print_info "CockroachDB Operator installed successfully"
}

verify_operator() {
    print_header "Verifying Operator Deployment"

    # Check operator deployment
    print_info "Checking operator deployment..."
    kubectl get deployment -n cockroach-operator-system

    # Wait for deployment to be available
    print_info "Waiting for operator deployment to be ready..."
    kubectl wait --for=condition=Available deployment/cockroach-operator-manager \
        -n cockroach-operator-system \
        --timeout=120s

    # Check operator pods
    print_info "Checking operator pods..."
    kubectl get pods -n cockroach-operator-system

    # Check CRDs
    print_info "Checking CockroachDB CRDs..."
    if kubectl get crd crdbclusters.crdb.cockroachlabs.com &>/dev/null; then
        print_info "CRD crdbclusters.crdb.cockroachlabs.com is installed"
    else
        print_error "CRD crdbclusters.crdb.cockroachlabs.com not found"
        exit 1
    fi

    print_info "Operator verification complete"
}

create_crdb_namespace() {
    print_header "Creating CockroachDB Namespace"

    # Create namespace for CockroachDB cluster
    if kubectl get namespace "${CRDB_NAMESPACE}" &>/dev/null; then
        print_warning "Namespace ${CRDB_NAMESPACE} already exists"
    else
        print_info "Creating namespace: ${CRDB_NAMESPACE}"
        kubectl create namespace "${CRDB_NAMESPACE}"
        print_info "Namespace ${CRDB_NAMESPACE} created"
    fi
}

main() {
    print_header "Phase 3: CockroachDB Operator Setup"
    print_info "This script will deploy the CockroachDB Kubernetes Operator"
    echo ""

    check_prerequisites
    load_config

    echo ""
    print_info "The following components will be deployed:"
    echo "  - CockroachDB Operator ${COCKROACHDB_OPERATOR_VERSION}"
    echo "  - CockroachDB CRDs (Custom Resource Definitions)"
    echo "  - Operator namespace: cockroach-operator-system"
    echo "  - CockroachDB cluster namespace: ${CRDB_NAMESPACE}"
    echo ""

    read -p "Proceed with setup? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_warning "Setup cancelled"
        exit 0
    fi

    # Execute setup steps
    install_operator
    verify_operator
    create_crdb_namespace

    print_header "Phase 3 Complete!"
    print_info "CockroachDB Operator is ready"
    print_info "Next: Proceed to Phase 4 (CockroachDB Cluster)"
}

# Run main function
main "$@"
