#!/bin/bash
set -e

#######################################
# Phase 4: CockroachDB Cluster Setup
#######################################
# Deploys a 3-node CockroachDB cluster with TLS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/config.env"
GENERATED_DIR="${ROOT_DIR}/generated/phase4"

mkdir -p "${GENERATED_DIR}"

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
    for tool in kubectl envsubst; do
        if ! command -v $tool &> /dev/null; then
            print_error "$tool is not installed"
            missing=$((missing + 1))
        else
            print_info "$tool is installed"
        fi
    done

    if [ $missing -gt 0 ]; then
        print_error "Missing required tools"
        exit 1
    fi

    # Check kubectl connection
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    # Check if cockroachdb namespace exists
    if ! kubectl get namespace "${CRDB_NAMESPACE}" &> /dev/null; then
        print_error "Namespace ${CRDB_NAMESPACE} does not exist"
        print_error "Run Phase 3 setup first: cd ../phase3-operator && ./setup.sh"
        exit 1
    fi

    # Check if CockroachDB Operator is running
    if ! kubectl get deployment cockroach-operator-manager -n cockroach-operator-system &> /dev/null; then
        print_error "CockroachDB Operator not found"
        print_error "Run Phase 3 setup first: cd ../phase3-operator && ./setup.sh"
        exit 1
    fi

    # Check if vault-issuer exists
    if ! kubectl get clusterissuer vault-issuer &> /dev/null; then
        print_error "ClusterIssuer vault-issuer not found"
        print_error "Run Phase 2 setup first: cd ../phase2-certificates && ./setup.sh"
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
    print_info "  Cluster: ${CRDB_CLUSTER_NAME_EAST}"
    print_info "  Version: ${COCKROACHDB_VERSION}"
    print_info "  Nodes: ${CRDB_NODE_COUNT}"
    print_info "  Storage: ${CRDB_STORAGE_SIZE} (${STORAGE_CLASS_NAME})"
}

create_certificates() {
    print_header "Creating TLS Certificates"

    # Generate certificate manifests
    print_info "Generating certificate manifests..."
    envsubst < "${SCRIPT_DIR}/node-certificate.yaml.template" > "${GENERATED_DIR}/node-certificate.yaml"
    envsubst < "${SCRIPT_DIR}/client-certificate.yaml.template" > "${GENERATED_DIR}/client-certificate.yaml"

    # Apply certificates
    print_info "Creating node certificate..."
    kubectl apply -f "${GENERATED_DIR}/node-certificate.yaml"

    print_info "Creating client certificate..."
    kubectl apply -f "${GENERATED_DIR}/client-certificate.yaml"

    # Wait for certificates to be ready
    print_info "Waiting for node certificate to be ready..."
    kubectl wait --for=condition=Ready certificate/cockroachdb-node \
        -n "${CRDB_NAMESPACE}" \
        --timeout=300s

    print_info "Waiting for client certificate to be ready..."
    kubectl wait --for=condition=Ready certificate/cockroachdb-client-root \
        -n "${CRDB_NAMESPACE}" \
        --timeout=300s

    print_info "Certificates created and ready"
}

deploy_cluster() {
    print_header "Deploying CockroachDB Cluster"

    # Check if cluster already exists
    if kubectl get crdbcluster "${CRDB_CLUSTER_NAME_EAST}" -n "${CRDB_NAMESPACE}" &> /dev/null; then
        print_warning "CockroachDB cluster already exists"
        return 0
    fi

    # Generate cluster manifest
    print_info "Generating cluster manifest..."
    envsubst < "${SCRIPT_DIR}/crdb-cluster.yaml.template" > "${GENERATED_DIR}/crdb-cluster.yaml"

    # Apply cluster
    print_info "Creating CrdbCluster resource..."
    kubectl apply -f "${GENERATED_DIR}/crdb-cluster.yaml"

    print_info "Cluster resource created (operator will provision pods)"
}

wait_for_cluster() {
    print_header "Waiting for Cluster to be Ready"

    print_info "Waiting for pods to be created..."

    # Wait for all pods to exist
    local max_wait=300
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        POD_COUNT=$(kubectl get pods -n "${CRDB_NAMESPACE}" -l app.kubernetes.io/name=cockroachdb --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$POD_COUNT" -eq "${CRDB_NODE_COUNT}" ]; then
            print_info "All ${CRDB_NODE_COUNT} pods created"
            break
        fi

        if [[ $((elapsed % 10)) -eq 0 ]]; then
            echo "  Waiting for pods... (${POD_COUNT}/${CRDB_NODE_COUNT} created, ${elapsed}s elapsed)"
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [ "$POD_COUNT" -ne "${CRDB_NODE_COUNT}" ]; then
        print_error "Timeout waiting for pods to be created"
        print_error "Check operator logs: kubectl logs -n cockroach-operator-system deployment/cockroach-operator-manager"
        exit 1
    fi

    # Pods won't be ready until cluster is initialized, so just verify they're running
    print_info "Verifying pods are running..."
    for i in $(seq 0 $((CRDB_NODE_COUNT - 1))); do
        POD_NAME="${CRDB_CLUSTER_NAME_EAST}-${i}"
        print_info "Checking ${POD_NAME}..."

        # Wait for pod to exist and be in Running state
        local max_wait=120
        local elapsed=0
        while [ $elapsed -lt $max_wait ]; do
            POD_STATUS=$(kubectl get pod "${POD_NAME}" -n "${CRDB_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [ "$POD_STATUS" == "Running" ]; then
                print_info "${POD_NAME} is running"
                break
            fi
            sleep 5
            elapsed=$((elapsed + 5))
        done

        if [ "$POD_STATUS" != "Running" ]; then
            print_error "${POD_NAME} is not running (status: ${POD_STATUS})"
            exit 1
        fi
    done

    print_info "All pods are running (will become ready after initialization)"
}

initialize_cluster() {
    print_header "Initializing Cluster"

    local POD_NAME="${CRDB_CLUSTER_NAME_EAST}-0"

    # Check if cluster is already initialized
    print_info "Checking cluster status..."
    if kubectl exec -n "${CRDB_NAMESPACE}" "${POD_NAME}" -- ./cockroach node status --certs-dir=/cockroach/cockroach-certs &> /dev/null; then
        print_warning "Cluster already initialized"
        return 0
    fi

    # Initialize cluster
    print_info "Running cluster initialization..."
    kubectl exec -n "${CRDB_NAMESPACE}" "${POD_NAME}" -- ./cockroach init --certs-dir=/cockroach/cockroach-certs

    # Wait for cluster to be ready
    print_info "Waiting for cluster to stabilize..."
    sleep 10

    # Verify all nodes are live
    print_info "Verifying cluster status..."
    kubectl exec -n "${CRDB_NAMESPACE}" "${POD_NAME}" -- ./cockroach node status --certs-dir=/cockroach/cockroach-certs

    print_info "Cluster initialized successfully"
}

display_cluster_info() {
    print_header "Cluster Information"

    echo "Cluster Name: ${CRDB_CLUSTER_NAME_EAST}"
    echo "Namespace: ${CRDB_NAMESPACE}"
    echo "Nodes: ${CRDB_NODE_COUNT}"
    echo "Version: ${COCKROACHDB_VERSION}"
    echo ""

    echo "Services:"
    kubectl get svc -n "${CRDB_NAMESPACE}"
    echo ""

    echo "Pods:"
    kubectl get pods -n "${CRDB_NAMESPACE}" -o wide
    echo ""

    echo "PVCs:"
    kubectl get pvc -n "${CRDB_NAMESPACE}"
    echo ""

    print_info "To access the SQL shell:"
    echo "  kubectl exec -it -n ${CRDB_NAMESPACE} ${CRDB_CLUSTER_NAME_EAST}-0 -- ./cockroach sql --certs-dir=/cockroach/cockroach-certs"
    echo ""

    print_info "To access the Admin UI:"
    echo "  kubectl port-forward -n ${CRDB_NAMESPACE} svc/${CRDB_CLUSTER_NAME_EAST}-public 8080:8080"
    echo "  Then open: http://localhost:8080"
}

main() {
    print_header "Phase 4: CockroachDB Cluster Setup"
    print_info "This script will deploy a ${CRDB_NODE_COUNT}-node CockroachDB cluster"
    echo ""

    check_prerequisites
    load_config

    echo ""
    print_info "The following will be deployed:"
    echo "  - CockroachDB v${COCKROACHDB_VERSION}"
    echo "  - ${CRDB_NODE_COUNT} nodes (one per AZ)"
    echo "  - ${CRDB_STORAGE_SIZE} storage per node (${STORAGE_CLASS_NAME})"
    echo "  - TLS enabled (Vault-issued certificates)"
    echo "  - Namespace: ${CRDB_NAMESPACE}"
    echo ""

    read -p "Proceed with setup? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_warning "Setup cancelled"
        exit 0
    fi

    # Execute setup steps
    create_certificates
    deploy_cluster
    wait_for_cluster
    initialize_cluster
    display_cluster_info

    print_header "Phase 4 Complete!"
    print_info "CockroachDB cluster is ready"
    print_info "Next: Proceed to Phase 5 (Connection Pooling with PgBouncer)"
}

# Run main function
main "$@"
