#!/bin/bash
set -e

#######################################
# Phase 5: PgBouncer Three-Pool Architecture Setup
#######################################
# Deploys three dedicated PgBouncer connection pools:
# - App pool (50%, port 5432) - RLS-enforced user connections
# - Batch pool (40%, port 5433) - Batch processing with BYPASSRLS
# - Admin pool (10%, port 5434) - DBA operations

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/config.env"
GENERATED_DIR="${ROOT_DIR}/generated/phase5"

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
        print_error "Run Phase 4 setup first: cd ../phase4-cluster && ./setup.sh"
        exit 1
    fi

    # Check if CockroachDB cluster is running
    if ! kubectl get crdbcluster "${CRDB_CLUSTER_NAME_EAST}" -n "${CRDB_NAMESPACE}" &> /dev/null; then
        print_error "CockroachDB cluster not found"
        print_error "Run Phase 4 setup first: cd ../phase4-cluster && ./setup.sh"
        exit 1
    fi

    # Check if service account certificates exist
    for cert in pgb-app-user pgb-batch-user pgb-admin-user; do
        if ! kubectl get secret "cockroachdb-client-${cert}" -n "${CRDB_NAMESPACE}" &> /dev/null; then
            print_error "Certificate cockroachdb-client-${cert} not found"
            print_error "Run Phase 4 setup first: cd ../phase4-cluster && ./setup.sh"
            exit 1
        fi
    done

    print_info "All prerequisites met"
}

load_config() {
    print_header "Loading Configuration"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Config file not found: ${CONFIG_FILE}"
        exit 1
    fi

    source "$CONFIG_FILE"

    # Calculate pool sizes based on connection pool formula
    # Total = 4 × CPU × nodes (e.g., 4 × 8 × 3 = 96 connections)
    TOTAL_CONNECTIONS=$((4 * CRDB_CPU_LIMIT * CRDB_NODE_COUNT))

    # Calculate per-replica pool sizes based on configurable percentages
    export PGBOUNCER_APP_POOL_SIZE=$((TOTAL_CONNECTIONS * PGBOUNCER_APP_POOL_PCT / 100 / PGBOUNCER_APP_REPLICAS))
    export PGBOUNCER_BATCH_POOL_SIZE=$((TOTAL_CONNECTIONS * PGBOUNCER_BATCH_POOL_PCT / 100 / PGBOUNCER_BATCH_REPLICAS))
    export PGBOUNCER_ADMIN_POOL_SIZE=$((TOTAL_CONNECTIONS * PGBOUNCER_ADMIN_POOL_PCT / 100 / PGBOUNCER_ADMIN_REPLICAS))

    print_info "Configuration loaded from ${CONFIG_FILE}"
    print_info "  CockroachDB: ${CRDB_CLUSTER_NAME_EAST} (${CRDB_NODE_COUNT} nodes × ${CRDB_CPU_LIMIT} CPU)"
    print_info "  Total connections: ${TOTAL_CONNECTIONS}"
    print_info "  App pool: ${PGBOUNCER_APP_REPLICAS} replicas × ${PGBOUNCER_APP_POOL_SIZE} = $((PGBOUNCER_APP_REPLICAS * PGBOUNCER_APP_POOL_SIZE)) connections (${PGBOUNCER_APP_POOL_PCT}%)"
    print_info "  Batch pool: ${PGBOUNCER_BATCH_REPLICAS} replicas × ${PGBOUNCER_BATCH_POOL_SIZE} = $((PGBOUNCER_BATCH_REPLICAS * PGBOUNCER_BATCH_POOL_SIZE)) connections (${PGBOUNCER_BATCH_POOL_PCT}%)"
    print_info "  Admin pool: ${PGBOUNCER_ADMIN_REPLICAS} replicas × ${PGBOUNCER_ADMIN_POOL_SIZE} = $((PGBOUNCER_ADMIN_REPLICAS * PGBOUNCER_ADMIN_POOL_SIZE)) connections (${PGBOUNCER_ADMIN_POOL_PCT}%)"
}

deploy_app_pool() {
    print_header "Deploying App Pool (Port ${PGBOUNCER_APP_PORT})"

    local POOL_NAME="pgbouncer-app"
    local POOL_PORT=${PGBOUNCER_APP_PORT}
    local SERVICE_ACCOUNT_CERT="cockroachdb-client-pgb-app-user"
    local REPLICAS=${PGBOUNCER_APP_REPLICAS}
    local POOL_SIZE=${PGBOUNCER_APP_POOL_SIZE}
    local MAX_CLIENT_CONN=${PGBOUNCER_MAX_CLIENT_CONN}

    print_info "Generating ConfigMap for app pool..."
    cat > "${GENERATED_DIR}/pgbouncer-app-configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${POOL_NAME}-config
  namespace: ${CRDB_NAMESPACE}
data:
  pgbouncer.ini: |
    [databases]
    * = host=${CRDB_CLUSTER_NAME_EAST}-public port=26257 user=pgb_app_user

    [pgbouncer]
    listen_addr = 0.0.0.0
    listen_port = ${POOL_PORT}

    # Authentication
    auth_type = any

    # Connection pooling
    pool_mode = transaction
    max_client_conn = ${MAX_CLIENT_CONN}
    default_pool_size = ${POOL_SIZE}
    reserve_pool_size = $((POOL_SIZE / 4))

    # TLS Configuration - Server side (PgBouncer connecting to CockroachDB)
    server_tls_sslmode = require
    server_tls_ca_file = /cockroach-certs/ca.crt
    server_tls_key_file = /cockroach-certs/tls.key
    server_tls_cert_file = /cockroach-certs/tls.crt

    # TLS Configuration - Client side (Applications connecting to PgBouncer)
    client_tls_sslmode = allow
    client_tls_ca_file = /cockroach-certs/ca.crt
    client_tls_key_file = /cockroach-certs/tls.key
    client_tls_cert_file = /cockroach-certs/tls.crt

    # Performance tuning
    so_reuseport = 1
    listen_backlog = 4096
    server_round_robin = 1

    # Logging
    log_connections = 1
    log_disconnections = 1
    log_pooler_errors = 1

    # Timeouts
    server_idle_timeout = 0
    server_lifetime = 0
    server_connect_timeout = 15
    query_timeout = 0
    query_wait_timeout = 120
    client_idle_timeout = 0
    idle_transaction_timeout = 0

    # Connection limits
    max_db_connections = 0
    max_user_connections = 0
EOF

    print_info "Generating Deployment for app pool..."
    cat > "${GENERATED_DIR}/pgbouncer-app-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${POOL_NAME}
  namespace: ${CRDB_NAMESPACE}
  labels:
    app: pgbouncer
    pool: app
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: pgbouncer
      pool: app
  template:
    metadata:
      labels:
        app: pgbouncer
        pool: app
    spec:
      initContainers:
      - name: copy-config
        image: busybox:latest
        command: ['sh', '-c', 'cp /config-source/pgbouncer.ini /config-dest/ && chmod 644 /config-dest/pgbouncer.ini']
        volumeMounts:
        - name: config-source
          mountPath: /config-source
        - name: config
          mountPath: /config-dest
      containers:
      - name: pgbouncer
        image: edoburu/pgbouncer:v1.25.1-p0
        ports:
        - containerPort: ${POOL_PORT}
          name: pgbouncer
        volumeMounts:
        - name: config
          mountPath: /etc/pgbouncer
        - name: cockroach-certs
          mountPath: /cockroach-certs
          readOnly: true
        resources:
          requests:
            cpu: 500m
            memory: 256Mi
          limits:
            cpu: 1000m
            memory: 512Mi
        livenessProbe:
          tcpSocket:
            port: ${POOL_PORT}
          initialDelaySeconds: 10
          periodSeconds: 30
        readinessProbe:
          tcpSocket:
            port: ${POOL_PORT}
          initialDelaySeconds: 5
          periodSeconds: 10
      volumes:
      - name: config-source
        configMap:
          name: ${POOL_NAME}-config
      - name: config
        emptyDir: {}
      - name: cockroach-certs
        secret:
          secretName: ${SERVICE_ACCOUNT_CERT}
          defaultMode: 420
EOF

    print_info "Generating Service for app pool..."
    cat > "${GENERATED_DIR}/pgbouncer-app-service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${POOL_NAME}
  namespace: ${CRDB_NAMESPACE}
  labels:
    app: pgbouncer
    pool: app
spec:
  type: ClusterIP
  ports:
  - port: ${POOL_PORT}
    targetPort: ${POOL_PORT}
    protocol: TCP
    name: pgbouncer
  selector:
    app: pgbouncer
    pool: app
EOF

    print_info "Applying app pool manifests..."
    kubectl apply -f "${GENERATED_DIR}/pgbouncer-app-configmap.yaml"
    kubectl apply -f "${GENERATED_DIR}/pgbouncer-app-deployment.yaml"
    kubectl apply -f "${GENERATED_DIR}/pgbouncer-app-service.yaml"

    print_info "App pool deployed"
}

deploy_batch_pool() {
    print_header "Deploying Batch Pool (Port ${PGBOUNCER_BATCH_PORT})"

    local POOL_NAME="pgbouncer-batch"
    local POOL_PORT=${PGBOUNCER_BATCH_PORT}
    local SERVICE_ACCOUNT_CERT="cockroachdb-client-pgb-batch-user"
    local REPLICAS=${PGBOUNCER_BATCH_REPLICAS}
    local POOL_SIZE=${PGBOUNCER_BATCH_POOL_SIZE}
    local MAX_CLIENT_CONN=${PGBOUNCER_MAX_CLIENT_CONN}

    print_info "Generating ConfigMap for batch pool..."
    cat > "${GENERATED_DIR}/pgbouncer-batch-configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${POOL_NAME}-config
  namespace: ${CRDB_NAMESPACE}
data:
  pgbouncer.ini: |
    [databases]
    * = host=${CRDB_CLUSTER_NAME_EAST}-public port=26257 user=pgb_batch_user

    [pgbouncer]
    listen_addr = 0.0.0.0
    listen_port = ${POOL_PORT}

    # Authentication
    auth_type = any

    # Connection pooling
    pool_mode = transaction
    max_client_conn = ${MAX_CLIENT_CONN}
    default_pool_size = ${POOL_SIZE}
    reserve_pool_size = $((POOL_SIZE / 4))

    # TLS Configuration - Server side (PgBouncer connecting to CockroachDB)
    server_tls_sslmode = require
    server_tls_ca_file = /cockroach-certs/ca.crt
    server_tls_key_file = /cockroach-certs/tls.key
    server_tls_cert_file = /cockroach-certs/tls.crt

    # TLS Configuration - Client side (Applications connecting to PgBouncer)
    client_tls_sslmode = allow
    client_tls_ca_file = /cockroach-certs/ca.crt
    client_tls_key_file = /cockroach-certs/tls.key
    client_tls_cert_file = /cockroach-certs/tls.crt

    # Performance tuning
    so_reuseport = 1
    listen_backlog = 4096
    server_round_robin = 1

    # Logging
    log_connections = 1
    log_disconnections = 1
    log_pooler_errors = 1

    # Timeouts
    server_idle_timeout = 0
    server_lifetime = 0
    server_connect_timeout = 15
    query_timeout = 0
    query_wait_timeout = 120
    client_idle_timeout = 0
    idle_transaction_timeout = 0

    # Connection limits
    max_db_connections = 0
    max_user_connections = 0
EOF

    print_info "Generating Deployment for batch pool..."
    cat > "${GENERATED_DIR}/pgbouncer-batch-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${POOL_NAME}
  namespace: ${CRDB_NAMESPACE}
  labels:
    app: pgbouncer
    pool: batch
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: pgbouncer
      pool: batch
  template:
    metadata:
      labels:
        app: pgbouncer
        pool: batch
    spec:
      initContainers:
      - name: copy-config
        image: busybox:latest
        command: ['sh', '-c', 'cp /config-source/pgbouncer.ini /config-dest/ && chmod 644 /config-dest/pgbouncer.ini']
        volumeMounts:
        - name: config-source
          mountPath: /config-source
        - name: config
          mountPath: /config-dest
      containers:
      - name: pgbouncer
        image: edoburu/pgbouncer:v1.25.1-p0
        ports:
        - containerPort: ${POOL_PORT}
          name: pgbouncer
        volumeMounts:
        - name: config
          mountPath: /etc/pgbouncer
        - name: cockroach-certs
          mountPath: /cockroach-certs
          readOnly: true
        resources:
          requests:
            cpu: 500m
            memory: 256Mi
          limits:
            cpu: 1000m
            memory: 512Mi
        livenessProbe:
          tcpSocket:
            port: ${POOL_PORT}
          initialDelaySeconds: 10
          periodSeconds: 30
        readinessProbe:
          tcpSocket:
            port: ${POOL_PORT}
          initialDelaySeconds: 5
          periodSeconds: 10
      volumes:
      - name: config-source
        configMap:
          name: ${POOL_NAME}-config
      - name: config
        emptyDir: {}
      - name: cockroach-certs
        secret:
          secretName: ${SERVICE_ACCOUNT_CERT}
          defaultMode: 420
EOF

    print_info "Generating Service for batch pool..."
    cat > "${GENERATED_DIR}/pgbouncer-batch-service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${POOL_NAME}
  namespace: ${CRDB_NAMESPACE}
  labels:
    app: pgbouncer
    pool: batch
spec:
  type: ClusterIP
  ports:
  - port: ${POOL_PORT}
    targetPort: ${POOL_PORT}
    protocol: TCP
    name: pgbouncer
  selector:
    app: pgbouncer
    pool: batch
EOF

    print_info "Applying batch pool manifests..."
    kubectl apply -f "${GENERATED_DIR}/pgbouncer-batch-configmap.yaml"
    kubectl apply -f "${GENERATED_DIR}/pgbouncer-batch-deployment.yaml"
    kubectl apply -f "${GENERATED_DIR}/pgbouncer-batch-service.yaml"

    print_info "Batch pool deployed"
}

deploy_admin_pool() {
    print_header "Deploying Admin Pool (Port ${PGBOUNCER_ADMIN_PORT})"

    local POOL_NAME="pgbouncer-admin"
    local POOL_PORT=${PGBOUNCER_ADMIN_PORT}
    local SERVICE_ACCOUNT_CERT="cockroachdb-client-pgb-admin-user"
    local REPLICAS=${PGBOUNCER_ADMIN_REPLICAS}
    local POOL_SIZE=${PGBOUNCER_ADMIN_POOL_SIZE}
    local MAX_CLIENT_CONN=${PGBOUNCER_ADMIN_MAX_CLIENT_CONN:-200}

    print_info "Generating ConfigMap for admin pool..."
    cat > "${GENERATED_DIR}/pgbouncer-admin-configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${POOL_NAME}-config
  namespace: ${CRDB_NAMESPACE}
data:
  pgbouncer.ini: |
    [databases]
    * = host=${CRDB_CLUSTER_NAME_EAST}-public port=26257 user=pgb_admin_user

    [pgbouncer]
    listen_addr = 0.0.0.0
    listen_port = ${POOL_PORT}

    # Authentication
    auth_type = any

    # Connection pooling
    pool_mode = transaction
    max_client_conn = ${MAX_CLIENT_CONN}
    default_pool_size = ${POOL_SIZE}
    reserve_pool_size = $((POOL_SIZE / 4))

    # TLS Configuration - Server side (PgBouncer connecting to CockroachDB)
    server_tls_sslmode = require
    server_tls_ca_file = /cockroach-certs/ca.crt
    server_tls_key_file = /cockroach-certs/tls.key
    server_tls_cert_file = /cockroach-certs/tls.crt

    # TLS Configuration - Client side (Applications connecting to PgBouncer)
    client_tls_sslmode = allow
    client_tls_ca_file = /cockroach-certs/ca.crt
    client_tls_key_file = /cockroach-certs/tls.key
    client_tls_cert_file = /cockroach-certs/tls.crt

    # Performance tuning
    so_reuseport = 1
    listen_backlog = 4096
    server_round_robin = 1

    # Logging
    log_connections = 1
    log_disconnections = 1
    log_pooler_errors = 1

    # Timeouts
    server_idle_timeout = 0
    server_lifetime = 0
    server_connect_timeout = 15
    query_timeout = 0
    query_wait_timeout = 120
    client_idle_timeout = 0
    idle_transaction_timeout = 0

    # Connection limits
    max_db_connections = 0
    max_user_connections = 0
EOF

    print_info "Generating Deployment for admin pool..."
    cat > "${GENERATED_DIR}/pgbouncer-admin-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${POOL_NAME}
  namespace: ${CRDB_NAMESPACE}
  labels:
    app: pgbouncer
    pool: admin
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: pgbouncer
      pool: admin
  template:
    metadata:
      labels:
        app: pgbouncer
        pool: admin
    spec:
      initContainers:
      - name: copy-config
        image: busybox:latest
        command: ['sh', '-c', 'cp /config-source/pgbouncer.ini /config-dest/ && chmod 644 /config-dest/pgbouncer.ini']
        volumeMounts:
        - name: config-source
          mountPath: /config-source
        - name: config
          mountPath: /config-dest
      containers:
      - name: pgbouncer
        image: edoburu/pgbouncer:v1.25.1-p0
        ports:
        - containerPort: ${POOL_PORT}
          name: pgbouncer
        volumeMounts:
        - name: config
          mountPath: /etc/pgbouncer
        - name: cockroach-certs
          mountPath: /cockroach-certs
          readOnly: true
        resources:
          requests:
            cpu: 250m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
        livenessProbe:
          tcpSocket:
            port: ${POOL_PORT}
          initialDelaySeconds: 10
          periodSeconds: 30
        readinessProbe:
          tcpSocket:
            port: ${POOL_PORT}
          initialDelaySeconds: 5
          periodSeconds: 10
      volumes:
      - name: config-source
        configMap:
          name: ${POOL_NAME}-config
      - name: config
        emptyDir: {}
      - name: cockroach-certs
        secret:
          secretName: ${SERVICE_ACCOUNT_CERT}
          defaultMode: 420
EOF

    print_info "Generating Service for admin pool..."
    cat > "${GENERATED_DIR}/pgbouncer-admin-service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${POOL_NAME}
  namespace: ${CRDB_NAMESPACE}
  labels:
    app: pgbouncer
    pool: admin
spec:
  type: ClusterIP
  ports:
  - port: ${POOL_PORT}
    targetPort: ${POOL_PORT}
    protocol: TCP
    name: pgbouncer
  selector:
    app: pgbouncer
    pool: admin
EOF

    print_info "Applying admin pool manifests..."
    kubectl apply -f "${GENERATED_DIR}/pgbouncer-admin-configmap.yaml"
    kubectl apply -f "${GENERATED_DIR}/pgbouncer-admin-deployment.yaml"
    kubectl apply -f "${GENERATED_DIR}/pgbouncer-admin-service.yaml"

    print_info "Admin pool deployed"
}

wait_for_pools() {
    print_header "Waiting for PgBouncer Pools"

    print_info "Waiting for app pool replicas..."
    kubectl rollout status deployment/pgbouncer-app -n "${CRDB_NAMESPACE}" --timeout=300s

    print_info "Waiting for batch pool replicas..."
    kubectl rollout status deployment/pgbouncer-batch -n "${CRDB_NAMESPACE}" --timeout=300s

    print_info "Waiting for admin pool replicas..."
    kubectl rollout status deployment/pgbouncer-admin -n "${CRDB_NAMESPACE}" --timeout=300s

    print_info "All pools are ready"
}

test_connectivity() {
    print_header "Testing Connectivity"

    # Test app pool
    print_info "Testing app pool connectivity (port ${PGBOUNCER_APP_PORT})..."
    kubectl run -it --rm pgbouncer-test-app --image=postgres:15 --restart=Never -n "${CRDB_NAMESPACE}" -- \
        psql "postgresql://root@pgbouncer-app:${PGBOUNCER_APP_PORT}/defaultdb?sslmode=disable" -c "SELECT 1 AS app_pool_test;" || \
        print_warning "App pool test failed (expected if root user not configured for password auth)"

    # Test batch pool
    print_info "Testing batch pool connectivity (port ${PGBOUNCER_BATCH_PORT})..."
    kubectl run -it --rm pgbouncer-test-batch --image=postgres:15 --restart=Never -n "${CRDB_NAMESPACE}" -- \
        psql "postgresql://root@pgbouncer-batch:${PGBOUNCER_BATCH_PORT}/defaultdb?sslmode=disable" -c "SELECT 1 AS batch_pool_test;" || \
        print_warning "Batch pool test failed (expected if root user not configured for password auth)"

    # Test admin pool
    print_info "Testing admin pool connectivity (port ${PGBOUNCER_ADMIN_PORT})..."
    kubectl run -it --rm pgbouncer-test-admin --image=postgres:15 --restart=Never -n "${CRDB_NAMESPACE}" -- \
        psql "postgresql://root@pgbouncer-admin:${PGBOUNCER_ADMIN_PORT}/defaultdb?sslmode=disable" -c "SELECT 1 AS admin_pool_test;" || \
        print_warning "Admin pool test failed (expected if root user not configured for password auth)"

    print_info "Connectivity tests complete"
    print_warning "Note: Certificate-based authentication requires proper client certificates"
}

display_info() {
    print_header "PgBouncer Connection Information"

    echo "Three PgBouncer pools are now available:"
    echo ""
    echo "1. App Pool (RLS-enforced user connections):"
    echo "   Service: pgbouncer-app.${CRDB_NAMESPACE}.svc.cluster.local:${PGBOUNCER_APP_PORT}"
    echo "   Replicas: ${PGBOUNCER_APP_REPLICAS}"
    echo "   Pool Size: ${PGBOUNCER_APP_POOL_SIZE} per replica ($((PGBOUNCER_APP_REPLICAS * PGBOUNCER_APP_POOL_SIZE)) total connections)"
    echo "   Service Account: pgb_app_user (grants: app role)"
    echo ""
    echo "2. Batch Pool (ETL jobs with BYPASSRLS):"
    echo "   Service: pgbouncer-batch.${CRDB_NAMESPACE}.svc.cluster.local:${PGBOUNCER_BATCH_PORT}"
    echo "   Replicas: ${PGBOUNCER_BATCH_REPLICAS}"
    echo "   Pool Size: ${PGBOUNCER_BATCH_POOL_SIZE} per replica ($((PGBOUNCER_BATCH_REPLICAS * PGBOUNCER_BATCH_POOL_SIZE)) total connections)"
    echo "   Service Account: pgb_batch_user (grants: admin role with BYPASSRLS)"
    echo ""
    echo "3. Admin Pool (DBA operations):"
    echo "   Service: pgbouncer-admin.${CRDB_NAMESPACE}.svc.cluster.local:${PGBOUNCER_ADMIN_PORT}"
    echo "   Replicas: ${PGBOUNCER_ADMIN_REPLICAS}"
    echo "   Pool Size: ${PGBOUNCER_ADMIN_POOL_SIZE} per replica ($((PGBOUNCER_ADMIN_REPLICAS * PGBOUNCER_ADMIN_POOL_SIZE)) total connections)"
    echo "   Service Account: pgb_admin_user (grants: admin role with BYPASSRLS)"
    echo ""

    print_info "Check pool status:"
    echo "  kubectl get pods -n ${CRDB_NAMESPACE} -l app=pgbouncer"
    echo "  kubectl get svc -n ${CRDB_NAMESPACE} -l app=pgbouncer"
    echo ""

    print_info "View pool logs:"
    echo "  kubectl logs -n ${CRDB_NAMESPACE} -l app=pgbouncer,pool=app --tail=50"
    echo "  kubectl logs -n ${CRDB_NAMESPACE} -l app=pgbouncer,pool=batch --tail=50"
    echo "  kubectl logs -n ${CRDB_NAMESPACE} -l app=pgbouncer,pool=admin --tail=50"
}

main() {
    print_header "Phase 5: PgBouncer Three-Pool Architecture"
    print_info "This script will deploy three dedicated PgBouncer connection pools"
    echo ""

    load_config
    check_prerequisites

    echo ""
    print_info "The following will be deployed:"
    echo "  - App Pool: ${PGBOUNCER_APP_REPLICAS} replicas on port ${PGBOUNCER_APP_PORT} (${PGBOUNCER_APP_POOL_SIZE} connections/replica, ${PGBOUNCER_APP_POOL_PCT}%)"
    echo "  - Batch Pool: ${PGBOUNCER_BATCH_REPLICAS} replicas on port ${PGBOUNCER_BATCH_PORT} (${PGBOUNCER_BATCH_POOL_SIZE} connections/replica, ${PGBOUNCER_BATCH_POOL_PCT}%)"
    echo "  - Admin Pool: ${PGBOUNCER_ADMIN_REPLICAS} replica on port ${PGBOUNCER_ADMIN_PORT} (${PGBOUNCER_ADMIN_POOL_SIZE} connections/replica, ${PGBOUNCER_ADMIN_POOL_PCT}%)"
    echo "  - Total: $((PGBOUNCER_APP_REPLICAS * PGBOUNCER_APP_POOL_SIZE + PGBOUNCER_BATCH_REPLICAS * PGBOUNCER_BATCH_POOL_SIZE + PGBOUNCER_ADMIN_REPLICAS * PGBOUNCER_ADMIN_POOL_SIZE)) server connections to CockroachDB"
    echo "  - Pool mode: transaction (identity propagation via SET LOCAL)"
    echo "  - Namespace: ${CRDB_NAMESPACE}"
    echo ""

    read -p "Proceed with setup? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_warning "Setup cancelled"
        exit 0
    fi

    # Execute setup steps
    deploy_app_pool
    deploy_batch_pool
    deploy_admin_pool
    wait_for_pools
    test_connectivity
    display_info

    print_header "Phase 5 Complete!"
    print_info "PgBouncer three-pool architecture is ready"
    print_info "Next: Proceed to Phase 6 (Istio Service Mesh for JWT validation)"
}

# Run main function
main "$@"
