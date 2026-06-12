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

    # Check if cockroachdb namespace exists, create if not
    if ! kubectl get namespace "${CRDB_NAMESPACE}" &> /dev/null; then
        print_warning "Namespace ${CRDB_NAMESPACE} does not exist, creating it..."
        kubectl create namespace "${CRDB_NAMESPACE}"
        print_info "Namespace ${CRDB_NAMESPACE} created"
    else
        print_info "Namespace ${CRDB_NAMESPACE} exists"
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

    # Check Okta configuration (optional)
    if [[ -n "${OKTA_ISSUER}" && -n "${OKTA_CLIENT_ID}" ]]; then
        print_info "  Okta: Configured"
    else
        print_warning "  Okta: Not configured (JWT authentication will be skipped)"
    fi
}

create_certificates() {
    print_header "Creating TLS Certificates"

    # Generate certificate manifests
    print_info "Generating node certificate manifest..."
    envsubst < "${SCRIPT_DIR}/node-certificate.yaml.template" > "${GENERATED_DIR}/node-certificate.yaml"

    print_info "Generating root client certificate manifest..."
    envsubst < "${SCRIPT_DIR}/client-certificate.yaml.template" > "${GENERATED_DIR}/client-certificate.yaml"

    # Generate service account certificates
    print_info "Generating service account certificate manifests..."

    # pgb_app_user
    export CLIENT_CERT_USER="pgb_app_user"
    export CLIENT_CERT_NAME="cockroachdb-client-pgb-app-user"
    envsubst < "${SCRIPT_DIR}/service-account-certificate.yaml.template" > "${GENERATED_DIR}/client-cert-pgb-app.yaml"

    # pgb_batch_user
    export CLIENT_CERT_USER="pgb_batch_user"
    export CLIENT_CERT_NAME="cockroachdb-client-pgb-batch-user"
    envsubst < "${SCRIPT_DIR}/service-account-certificate.yaml.template" > "${GENERATED_DIR}/client-cert-pgb-batch.yaml"

    # pgb_admin_user
    export CLIENT_CERT_USER="pgb_admin_user"
    export CLIENT_CERT_NAME="cockroachdb-client-pgb-admin-user"
    envsubst < "${SCRIPT_DIR}/service-account-certificate.yaml.template" > "${GENERATED_DIR}/client-cert-pgb-admin.yaml"

    # flyway_svc
    export CLIENT_CERT_USER="flyway_svc"
    export CLIENT_CERT_NAME="cockroachdb-client-flyway-svc"
    envsubst < "${SCRIPT_DIR}/service-account-certificate.yaml.template" > "${GENERATED_DIR}/client-cert-flyway.yaml"

    # Apply certificates
    print_info "Creating node certificate..."
    kubectl apply -f "${GENERATED_DIR}/node-certificate.yaml"

    print_info "Creating root client certificate..."
    kubectl apply -f "${GENERATED_DIR}/client-certificate.yaml"

    print_info "Creating service account certificates..."
    kubectl apply -f "${GENERATED_DIR}/client-cert-pgb-app.yaml"
    kubectl apply -f "${GENERATED_DIR}/client-cert-pgb-batch.yaml"
    kubectl apply -f "${GENERATED_DIR}/client-cert-pgb-admin.yaml"
    kubectl apply -f "${GENERATED_DIR}/client-cert-flyway.yaml"

    # Wait for certificates to be ready
    print_info "Waiting for node certificate to be ready..."
    kubectl wait --for=condition=Ready certificate/cockroachdb-node \
        -n "${CRDB_NAMESPACE}" \
        --timeout=300s

    print_info "Waiting for root client certificate to be ready..."
    kubectl wait --for=condition=Ready certificate/cockroachdb-client-root \
        -n "${CRDB_NAMESPACE}" \
        --timeout=300s

    print_info "Waiting for service account certificates to be ready..."
    kubectl wait --for=condition=Ready certificate/cockroachdb-client-pgb-app-user \
        -n "${CRDB_NAMESPACE}" \
        --timeout=300s
    kubectl wait --for=condition=Ready certificate/cockroachdb-client-pgb-batch-user \
        -n "${CRDB_NAMESPACE}" \
        --timeout=300s
    kubectl wait --for=condition=Ready certificate/cockroachdb-client-pgb-admin-user \
        -n "${CRDB_NAMESPACE}" \
        --timeout=300s
    kubectl wait --for=condition=Ready certificate/cockroachdb-client-flyway-svc \
        -n "${CRDB_NAMESPACE}" \
        --timeout=300s

    print_info "All certificates created and ready"
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

configure_jwt_authentication() {
    print_header "Configuring JWT Authentication"

    local POD_NAME="${CRDB_CLUSTER_NAME_EAST}-0"

    # Check if Okta config is present
    if [[ -z "${OKTA_ISSUER}" || -z "${OKTA_CLIENT_ID}" ]]; then
        print_warning "Okta configuration not found in config.env"
        print_warning "Skipping JWT authentication setup"
        print_warning "To enable JWT authentication, add to config.env:"
        echo "  export OKTA_ISSUER=\"https://your-okta-domain/oauth2/default\""
        echo "  export OKTA_CLIENT_ID=\"your-client-id\""
        echo "  export OKTA_AUDIENCE=\"\${OKTA_CLIENT_ID}\"  # Or custom audience"
        return 0
    fi

    # Default audience to CLIENT_ID if not set
    OKTA_AUDIENCE="${OKTA_AUDIENCE:-${OKTA_CLIENT_ID}}"

    print_info "Enabling JWT authentication and authorization..."
    kubectl exec -n "${CRDB_NAMESPACE}" "${POD_NAME}" -- \
        ./cockroach sql --certs-dir=/cockroach/cockroach-certs -e "
        SET CLUSTER SETTING server.jwt_authentication.enabled = true;
        SET CLUSTER SETTING server.jwt_authentication.authorization.enabled = true;
        SET CLUSTER SETTING security.provisioning.jwt.enabled = true;
        "

    print_info "Fetching JWKS from Okta: ${OKTA_ISSUER}/v1/keys"
    OKTA_KEYS=$(curl -sk "${OKTA_ISSUER}/v1/keys")

    print_info "Configuring JWKS..."
    kubectl exec -n "${CRDB_NAMESPACE}" "${POD_NAME}" -- \
        ./cockroach sql --certs-dir=/cockroach/cockroach-certs -e \
        "SET CLUSTER SETTING server.jwt_authentication.jwks = '${OKTA_KEYS}';"

    print_info "Configuring issuer: ${OKTA_ISSUER}"
    kubectl exec -n "${CRDB_NAMESPACE}" "${POD_NAME}" -- \
        ./cockroach sql --certs-dir=/cockroach/cockroach-certs -e \
        "SET CLUSTER SETTING server.jwt_authentication.issuers.configuration = '${OKTA_ISSUER}';"

    print_info "Setting JWT audience: ${OKTA_AUDIENCE}"
    kubectl exec -n "${CRDB_NAMESPACE}" "${POD_NAME}" -- \
        ./cockroach sql --certs-dir=/cockroach/cockroach-certs -e \
        "SET CLUSTER SETTING server.jwt_authentication.audience = '${OKTA_AUDIENCE}';"

    print_info "Configuring identity mapping (email -> username)..."
    kubectl exec -n "${CRDB_NAMESPACE}" "${POD_NAME}" -- \
        ./cockroach sql --certs-dir=/cockroach/cockroach-certs -e \
        "SET CLUSTER SETTING server.identity_map.configuration = '${OKTA_ISSUER} /^(.*)@.*\$/ \\1';"

    print_info "Configuring group claim for role mapping..."
    kubectl exec -n "${CRDB_NAMESPACE}" "${POD_NAME}" -- \
        ./cockroach sql --certs-dir=/cockroach/cockroach-certs -e \
        "SET CLUSTER SETTING server.jwt_authentication.group_claim = 'groups';"

    print_info "JWT authentication configured successfully with:"
    echo "  ✓ Auto-provisioning enabled (users created from JWT)"
    echo "  ✓ Authorization enabled (role mapping from groups claim)"
    echo "  ✓ Identity mapping: email -> username (strips @domain)"
    echo "  ✓ Group claim: 'groups' for role assignment"
}

create_role_hierarchy() {
    print_header "Creating Role Hierarchy"

    local POD_NAME="${CRDB_CLUSTER_NAME_EAST}-0"

    print_info "Creating parent roles (NOLOGIN)..."

    # Create parent roles
    kubectl exec -n "${CRDB_NAMESPACE}" "${POD_NAME}" -- \
        ./cockroach sql --certs-dir=/cockroach/cockroach-certs -e "
        -- Parent roles (NOLOGIN)
        CREATE ROLE IF NOT EXISTS readonly NOLOGIN;
        CREATE ROLE IF NOT EXISTS app NOLOGIN;
        CREATE ROLE IF NOT EXISTS pipeline NOLOGIN;
        CREATE ROLE IF NOT EXISTS powerbi NOLOGIN;
        CREATE ROLE IF NOT EXISTS compliance NOLOGIN;
        CREATE ROLE IF NOT EXISTS developer NOLOGIN;
        CREATE ROLE IF NOT EXISTS admin NOLOGIN;
        "

    print_info "Granting role inheritance..."
    kubectl exec -n "${CRDB_NAMESPACE}" "${POD_NAME}" -- \
        ./cockroach sql --certs-dir=/cockroach/cockroach-certs -e "
        -- app inherits readonly
        GRANT readonly TO app;
        "

    print_info "Creating Okta-mapped roles..."
    kubectl exec -n "${CRDB_NAMESPACE}" "${POD_NAME}" -- \
        ./cockroach sql --certs-dir=/cockroach/cockroach-certs -e "
        -- Okta-mapped roles (NOLOGIN)
        CREATE ROLE IF NOT EXISTS crdb_advisor_team_east NOLOGIN;
        CREATE ROLE IF NOT EXISTS crdb_advisor_team_west NOLOGIN;
        CREATE ROLE IF NOT EXISTS crdb_client_services NOLOGIN;
        CREATE ROLE IF NOT EXISTS crdb_compliance_team NOLOGIN;
        CREATE ROLE IF NOT EXISTS crdb_fiduciary_admin NOLOGIN;
        CREATE ROLE IF NOT EXISTS crdb_batch_service NOLOGIN;
        CREATE ROLE IF NOT EXISTS crdb_developers NOLOGIN;
        "

    print_info "Granting parent roles to Okta-mapped roles..."
    kubectl exec -n "${CRDB_NAMESPACE}" "${POD_NAME}" -- \
        ./cockroach sql --certs-dir=/cockroach/cockroach-certs -e "
        -- Grant parent roles to Okta-mapped roles
        GRANT app TO crdb_advisor_team_east;
        GRANT app TO crdb_advisor_team_west;
        GRANT readonly TO crdb_client_services;
        GRANT compliance TO crdb_compliance_team;
        GRANT app TO crdb_fiduciary_admin;
        GRANT admin TO crdb_batch_service;
        GRANT developer TO crdb_developers;
        "

    print_info "Role hierarchy created successfully"
}

create_service_accounts() {
    print_header "Creating Service Account Users"

    local POD_NAME="${CRDB_CLUSTER_NAME_EAST}-0"

    print_info "Creating service account users (certificate-only authentication)..."
    kubectl exec -n "${CRDB_NAMESPACE}" "${POD_NAME}" -- \
        ./cockroach sql --certs-dir=/cockroach/cockroach-certs -e "
        -- Service account users (LOGIN, certificate-only authentication)
        CREATE USER IF NOT EXISTS pgb_app_user WITH LOGIN;
        CREATE USER IF NOT EXISTS pgb_batch_user WITH LOGIN;
        CREATE USER IF NOT EXISTS pgb_admin_user WITH LOGIN;
        CREATE USER IF NOT EXISTS flyway_svc WITH LOGIN;
        "

    print_info "Granting roles to service accounts..."
    kubectl exec -n "${CRDB_NAMESPACE}" "${POD_NAME}" -- \
        ./cockroach sql --certs-dir=/cockroach/cockroach-certs -e "
        -- Grant roles to service accounts
        GRANT app TO pgb_app_user;
        GRANT admin TO pgb_batch_user WITH ADMIN OPTION;
        GRANT admin TO pgb_admin_user WITH ADMIN OPTION;
        GRANT admin TO flyway_svc WITH ADMIN OPTION;
        "

    print_info "Service account users created successfully"
}

create_databases() {
    print_header "Creating Databases"

    local POD_NAME="${CRDB_CLUSTER_NAME_EAST}-0"

    print_info "Creating metadata database..."
    kubectl exec -n "${CRDB_NAMESPACE}" "${POD_NAME}" -- \
        ./cockroach sql --certs-dir=/cockroach/cockroach-certs -e \
        "CREATE DATABASE IF NOT EXISTS metadata;"

    print_info "Creating staging database..."
    kubectl exec -n "${CRDB_NAMESPACE}" "${POD_NAME}" -- \
        ./cockroach sql --certs-dir=/cockroach/cockroach-certs -e \
        "CREATE DATABASE IF NOT EXISTS staging;"

    print_info "Creating production database..."
    kubectl exec -n "${CRDB_NAMESPACE}" "${POD_NAME}" -- \
        ./cockroach sql --certs-dir=/cockroach/cockroach-certs -e \
        "CREATE DATABASE IF NOT EXISTS production;"

    print_info "Databases created successfully"
}

grant_database_permissions() {
    print_header "Granting Database Permissions"

    local POD_NAME="${CRDB_CLUSTER_NAME_EAST}-0"

    print_info "Granting permissions on databases..."
    kubectl exec -n "${CRDB_NAMESPACE}" "${POD_NAME}" -- \
        ./cockroach sql --certs-dir=/cockroach/cockroach-certs -e "
        -- Grant database access
        GRANT ALL ON DATABASE metadata TO app;
        GRANT ALL ON DATABASE metadata TO admin;
        GRANT CONNECT ON DATABASE metadata TO readonly;

        GRANT ALL ON DATABASE staging TO pipeline;
        GRANT ALL ON DATABASE staging TO admin;

        GRANT ALL ON DATABASE production TO app;
        GRANT ALL ON DATABASE production TO admin;
        GRANT CONNECT ON DATABASE production TO readonly;

        -- Grant schema access (Phase 7 Flyway will create tables and grant table-level permissions)
        USE production;
        GRANT USAGE ON SCHEMA public TO app;
        GRANT USAGE ON SCHEMA public TO readonly;
        GRANT ALL ON SCHEMA public TO admin;

        USE metadata;
        GRANT USAGE ON SCHEMA public TO app;
        GRANT ALL ON SCHEMA public TO admin;

        USE staging;
        GRANT USAGE ON SCHEMA public TO pipeline;
        GRANT ALL ON SCHEMA public TO admin;
        "

    print_info "Database permissions granted"
    print_info "Note: All schema objects (tables, RLS policies) will be created by Flyway in Phase 7"
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
    print_info "This script will deploy a ${CRDB_NODE_COUNT}-node CockroachDB cluster with full data access controls"
    echo ""

    check_prerequisites
    load_config

    echo ""
    print_info "The following will be deployed:"
    echo "  - CockroachDB v${COCKROACHDB_VERSION}"
    echo "  - ${CRDB_NODE_COUNT} nodes (one per AZ)"
    echo "  - ${CRDB_STORAGE_SIZE} storage per node (${STORAGE_CLASS_NAME})"
    echo "  - TLS enabled (Vault-issued certificates)"
    echo "  - JWT authentication (Okta OIDC integration)"
    echo "  - Role hierarchy (parent + Okta-mapped roles)"
    echo "  - Service account users (4 certificates)"
    echo "  - Three databases (metadata, staging, production)"
    echo "  - Row-Level Security foundation"
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
    configure_jwt_authentication
    create_role_hierarchy
    create_service_accounts
    create_databases
    grant_database_permissions
    display_cluster_info

    print_header "Phase 4 Complete!"
    print_info "CockroachDB cluster infrastructure is ready:"
    echo "  ✓ JWT authentication configured (Okta OIDC)"
    echo "  ✓ Role hierarchy created (parent + Okta-mapped roles)"
    echo "  ✓ Service account users created (pgb_app_user, pgb_batch_user, pgb_admin_user, flyway_svc)"
    echo "  ✓ Three databases created (metadata, staging, production)"
    echo "  ✓ Database permissions granted to roles"
    echo ""
    print_info "Note: Schema objects (tables, RLS policies) will be created by Flyway in Phase 7"
    print_info "Next: Proceed to Phase 5 (PgBouncer Three-Pool Architecture)"
}

# Run main function
main "$@"
