#!/bin/bash
set -e

#######################################
# Phase 2: Certificates Setup
#######################################
# Deploys HashiCorp Vault and cert-manager for certificate management

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/config.env"
GENERATED_DIR="${ROOT_DIR}/generated/phase2"

# Create generated directory if it doesn't exist
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

    local missing_tools=()

    for tool in kubectl helm jq; do
        if command -v $tool &> /dev/null; then
            print_info "$tool is installed ($(command -v $tool))"
        else
            print_error "$tool is not installed"
            missing_tools+=($tool)
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi

    # Check if kubectl can connect to cluster
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    print_info "All prerequisites met"
}

load_config() {
    print_header "Loading Configuration"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    source "$CONFIG_FILE"

    print_info "Configuration loaded from $CONFIG_FILE"
    print_info "  Cluster: ${CLUSTER_NAME_EAST}"
    print_info "  Region: ${AWS_REGION_EAST}"
}

install_vault() {
    print_header "Installing HashiCorp Vault"

    # Check if Vault already installed
    if helm list -n vault 2>/dev/null | grep -q vault; then
        print_warning "Vault already installed"
        return 0
    fi

    # Create namespace
    if ! kubectl get namespace vault &>/dev/null; then
        kubectl create namespace vault
        print_info "Created vault namespace"
    fi

    # Add Vault Helm repo
    print_info "Adding HashiCorp Helm repository..."
    helm repo add hashicorp https://helm.releases.hashicorp.com
    helm repo update

    # Install Vault in HA mode with Raft storage
    print_info "Installing Vault (HA mode with Raft storage)..."
    helm install vault hashicorp/vault \
        --namespace vault \
        --set server.ha.enabled=true \
        --set server.ha.replicas=3 \
        --set server.ha.raft.enabled=true \
        --set server.ha.raft.setNodeId=true \
        --set server.service.enabled=true \
        --set server.dataStorage.enabled=true \
        --set server.dataStorage.size=10Gi \
        --set server.dataStorage.storageClass="${STORAGE_CLASS_NAME}" \
        --set ui.enabled=true \
        --set ui.serviceType=ClusterIP

    print_info "Waiting for Vault pods to be created..."
    sleep 10

    # Wait for at least one pod to be ready (for initialization)
    print_info "Waiting for Vault pod 0 to be ready for initialization..."
    kubectl wait --for=condition=Ready pod/vault-0 -n vault --timeout=300s || true

    print_info "Vault installed successfully"
}

initialize_vault() {
    print_header "Initializing Vault"

    # Check if Vault is already initialized
    if kubectl exec -n vault vault-0 -- vault status &>/dev/null; then
        print_warning "Vault already initialized"
        return 0
    fi

    print_info "Initializing Vault with 5 key shares and threshold of 3..."

    # Initialize Vault and capture output
    INIT_OUTPUT=$(kubectl exec -n vault vault-0 -- vault operator init \
        -key-shares=5 \
        -key-threshold=3 \
        -format=json)

    # Extract unseal keys and root token
    UNSEAL_KEY_1=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
    UNSEAL_KEY_2=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[1]')
    UNSEAL_KEY_3=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[2]')
    UNSEAL_KEY_4=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[3]')
    UNSEAL_KEY_5=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[4]')
    ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

    # Save to local file (in real production, use a secrets manager)
    VAULT_KEYS_FILE="${GENERATED_DIR}/vault-keys.json"
    echo "$INIT_OUTPUT" > "$VAULT_KEYS_FILE"
    chmod 600 "$VAULT_KEYS_FILE"

    print_info "Vault initialized successfully"
    print_warning "Unseal keys and root token saved to: ${VAULT_KEYS_FILE}"
    print_warning "IMPORTANT: Store these keys securely! They are needed to unseal Vault."
    echo ""
    echo "Unseal Keys (need 3 of 5 to unseal):"
    echo "  Key 1: ${UNSEAL_KEY_1}"
    echo "  Key 2: ${UNSEAL_KEY_2}"
    echo "  Key 3: ${UNSEAL_KEY_3}"
    echo "  Key 4: ${UNSEAL_KEY_4}"
    echo "  Key 5: ${UNSEAL_KEY_5}"
    echo ""
    echo "Root Token: ${ROOT_TOKEN}"
    echo ""
}

unseal_vault() {
    print_header "Unsealing Vault"

    # Load unseal keys
    VAULT_KEYS_FILE="${GENERATED_DIR}/vault-keys.json"
    if [[ ! -f "$VAULT_KEYS_FILE" ]]; then
        print_error "Vault keys file not found: ${VAULT_KEYS_FILE}"
        print_error "Please initialize Vault first or provide vault-keys.json"
        exit 1
    fi

    UNSEAL_KEY_1=$(jq -r '.unseal_keys_b64[0]' "$VAULT_KEYS_FILE")
    UNSEAL_KEY_2=$(jq -r '.unseal_keys_b64[1]' "$VAULT_KEYS_FILE")
    UNSEAL_KEY_3=$(jq -r '.unseal_keys_b64[2]' "$VAULT_KEYS_FILE")

    # Unseal vault-0 (primary node)
    print_info "Unsealing vault-0..."
    kubectl exec -n vault vault-0 -- vault operator unseal "$UNSEAL_KEY_1" > /dev/null
    kubectl exec -n vault vault-0 -- vault operator unseal "$UNSEAL_KEY_2" > /dev/null
    kubectl exec -n vault vault-0 -- vault operator unseal "$UNSEAL_KEY_3" > /dev/null
    print_info "vault-0 unsealed"

    # Join vault-1 and vault-2 to Raft cluster, then unseal
    for i in 1 2; do
        POD_NAME="vault-$i"

        # Check if pod is ready
        if ! kubectl get pod "$POD_NAME" -n vault &>/dev/null; then
            print_warning "Pod $POD_NAME not found, skipping"
            continue
        fi

        print_info "Joining $POD_NAME to Raft cluster..."
        kubectl exec -n vault "$POD_NAME" -- vault operator raft join http://vault-0.vault-internal:8200 || print_warning "$POD_NAME may already be in cluster"

        print_info "Unsealing $POD_NAME..."
        kubectl exec -n vault "$POD_NAME" -- vault operator unseal "$UNSEAL_KEY_1" > /dev/null
        kubectl exec -n vault "$POD_NAME" -- vault operator unseal "$UNSEAL_KEY_2" > /dev/null
        kubectl exec -n vault "$POD_NAME" -- vault operator unseal "$UNSEAL_KEY_3" > /dev/null

        print_info "$POD_NAME unsealed"
    done

    # Wait for all pods to be ready
    print_info "Waiting for all Vault pods to be ready..."
    kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=vault -n vault --timeout=120s

    print_info "All Vault pods unsealed and ready"
}

configure_vault_pki() {
    print_header "Configuring Vault PKI"

    # Load root token
    VAULT_KEYS_FILE="${GENERATED_DIR}/vault-keys.json"
    ROOT_TOKEN=$(jq -r '.root_token' "$VAULT_KEYS_FILE")

    # Port forward to Vault (in background)
    print_info "Starting port-forward to Vault..."
    kubectl port-forward -n vault svc/vault 8200:8200 &>/dev/null &
    PORT_FORWARD_PID=$!
    sleep 3

    export VAULT_ADDR="http://127.0.0.1:8200"
    export VAULT_TOKEN="$ROOT_TOKEN"

    # Enable PKI secrets engine
    print_info "Enabling PKI secrets engine..."
    if ! kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=$ROOT_TOKEN vault secrets list" | grep -q "^${VAULT_PKI_PATH}/"; then
        kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=$ROOT_TOKEN vault secrets enable -path=${VAULT_PKI_PATH} pki"
        print_info "PKI secrets engine enabled at ${VAULT_PKI_PATH}"
    else
        print_warning "PKI secrets engine already enabled"
    fi

    # Tune PKI max lease TTL
    print_info "Configuring PKI max lease TTL..."
    kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=$ROOT_TOKEN vault secrets tune -max-lease-ttl=87600h ${VAULT_PKI_PATH}"

    # Generate root CA
    print_info "Generating root CA certificate..."
    kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=$ROOT_TOKEN vault write ${VAULT_PKI_PATH}/root/generate/internal common_name='CockroachDB Root CA' ttl=87600h" \
        || print_warning "Root CA may already exist"

    # Configure CA and CRL URLs
    print_info "Configuring CA and CRL URLs..."
    kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=$ROOT_TOKEN vault write ${VAULT_PKI_PATH}/config/urls issuing_certificates=http://vault.vault.svc.cluster.local:8200/v1/${VAULT_PKI_PATH}/ca crl_distribution_points=http://vault.vault.svc.cluster.local:8200/v1/${VAULT_PKI_PATH}/crl"

    # Create role for CockroachDB node and client certificates (includes cluster name, namespace, and DNS_ZONE)
    print_info "Creating PKI role for CockroachDB node and client certificates..."
    kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=$ROOT_TOKEN vault write ${VAULT_PKI_PATH}/roles/cockroachdb-node allowed_domains=root,node,localhost,*.${CRDB_CLUSTER_NAME_EAST},*.${CRDB_CLUSTER_NAME_EAST}.${CRDB_NAMESPACE},*.${CRDB_CLUSTER_NAME_EAST}.${CRDB_NAMESPACE}.svc,*.${CRDB_CLUSTER_NAME_EAST}.${CRDB_NAMESPACE}.svc.cluster.local,*.cockroachdb,*.cockroachdb.${CRDB_NAMESPACE},*.cockroachdb.${CRDB_NAMESPACE}.svc,*.cockroachdb.${CRDB_NAMESPACE}.svc.cluster.local,*.cockroachdb.svc,*.cockroachdb.svc.cluster.local,*.${DNS_ZONE} allow_bare_domains=true allow_subdomains=true allow_localhost=true allow_ip_sans=true max_ttl=8760h key_type=rsa key_bits=2048 server_flag=true client_flag=true"

    # Create role for CockroachDB client certificates (includes DNS_ZONE for external access)
    print_info "Creating PKI role for CockroachDB client certificates..."
    kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=$ROOT_TOKEN vault write ${VAULT_PKI_PATH}/roles/cockroachdb-client allowed_domains=root,*.cockroachdb,*.cockroachdb.svc,*.cockroachdb.svc.cluster.local,*.${DNS_ZONE} allow_bare_domains=true allow_subdomains=true max_ttl=8760h key_type=rsa key_bits=2048 client_flag=true"

    # Kill port-forward
    kill $PORT_FORWARD_PID 2>/dev/null || true

    print_info "Vault PKI configured successfully"
}

configure_vault_k8s_auth() {
    print_header "Configuring Vault Kubernetes Authentication"

    # Load root token
    VAULT_KEYS_FILE="${GENERATED_DIR}/vault-keys.json"
    ROOT_TOKEN=$(jq -r '.root_token' "$VAULT_KEYS_FILE")

    # Enable Kubernetes auth method
    print_info "Enabling Kubernetes auth method..."
    if ! kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=$ROOT_TOKEN vault auth list" | grep -q "^${VAULT_K8S_AUTH_PATH_EAST}/"; then
        kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=$ROOT_TOKEN vault auth enable -path=${VAULT_K8S_AUTH_PATH_EAST} kubernetes"
        print_info "Kubernetes auth enabled at ${VAULT_K8S_AUTH_PATH_EAST}"
    else
        print_warning "Kubernetes auth already enabled"
    fi

    # Configure Kubernetes auth
    print_info "Configuring Kubernetes auth..."
    kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=$ROOT_TOKEN vault write auth/${VAULT_K8S_AUTH_PATH_EAST}/config kubernetes_host=https://kubernetes.default.svc:443"

    # Create policy for cert-manager (needs access to both node and client cert roles)
    print_info "Creating policy for cert-manager..."
    kubectl exec -i -n vault vault-0 -- sh -c "VAULT_TOKEN=$ROOT_TOKEN vault policy write cert-manager -" <<EOF
path "${VAULT_PKI_PATH}/sign/cockroachdb-node" {
  capabilities = ["create", "update"]
}

path "${VAULT_PKI_PATH}/issue/cockroachdb-node" {
  capabilities = ["create", "update"]
}

path "${VAULT_PKI_PATH}/sign/cockroachdb-client" {
  capabilities = ["create", "update"]
}

path "${VAULT_PKI_PATH}/issue/cockroachdb-client" {
  capabilities = ["create", "update"]
}
EOF

    # Create role for cert-manager
    print_info "Creating Kubernetes auth role for cert-manager..."
    kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=$ROOT_TOKEN vault write auth/${VAULT_K8S_AUTH_PATH_EAST}/role/${VAULT_ROLE_CERT_MANAGER} bound_service_account_names=cert-manager bound_service_account_namespaces=cert-manager policies=cert-manager ttl=24h"

    print_info "Vault Kubernetes auth configured"
}

install_cert_manager() {
    print_header "Installing cert-manager"

    # Check if cert-manager already installed
    if helm list -n cert-manager 2>/dev/null | grep -q cert-manager; then
        print_warning "cert-manager already installed"
        return 0
    fi

    # Create namespace
    if ! kubectl get namespace cert-manager &>/dev/null; then
        kubectl create namespace cert-manager
        print_info "Created cert-manager namespace"
    fi

    # Add Jetstack Helm repo
    print_info "Adding Jetstack Helm repository..."
    helm repo add jetstack https://charts.jetstack.io
    helm repo update

    # Install cert-manager CRDs first (more reliable than --set crds.enabled=true)
    print_info "Installing cert-manager CRDs..."
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.crds.yaml

    # Install cert-manager
    print_info "Installing cert-manager..."
    helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --version "${CERT_MANAGER_VERSION}" \
        --set global.leaderElection.namespace=cert-manager \
        --set startupapicheck.enabled=false \
        --wait --timeout=5m

    # Wait for cert-manager pods
    print_info "Waiting for cert-manager pods to be ready..."
    kubectl wait --for=condition=Ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=120s

    # Create RBAC for cert-manager to create service account tokens (required for Vault auth)
    print_info "Creating RBAC for cert-manager token creation..."
    kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cert-manager-vault-token-creator
rules:
- apiGroups: [""]
  resources: ["serviceaccounts/token"]
  verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cert-manager-vault-token-creator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cert-manager-vault-token-creator
subjects:
- kind: ServiceAccount
  name: cert-manager
  namespace: cert-manager
EOF

    print_info "cert-manager installed successfully"
}

create_vault_issuer() {
    print_header "Creating Vault ClusterIssuer"

    # Generate and apply Vault ClusterIssuer manifest
    print_info "Creating Vault ClusterIssuer..."
    envsubst < "${SCRIPT_DIR}/vault-issuer.yaml.template" > "${GENERATED_DIR}/vault-issuer.yaml"
    kubectl apply -f "${GENERATED_DIR}/vault-issuer.yaml"

    # Wait for issuer to be ready
    print_info "Waiting for ClusterIssuer to be ready..."
    sleep 5
    kubectl get clusterissuer vault-issuer -o jsonpath='{.status.conditions[0].message}' 2>/dev/null || echo "Checking..."
    echo ""

    print_info "Vault ClusterIssuer created"
}

test_certificate() {
    print_header "Testing Certificate Issuance"

    print_info "Creating test certificate..."
    kubectl apply -f "${SCRIPT_DIR}/test-certificate.yaml"

    print_info "Waiting for certificate to be issued..."
    sleep 10

    # Check certificate status
    CERT_STATUS=$(kubectl get certificate test-cert -n default -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "NotFound")

    if [[ "$CERT_STATUS" == "Ready" ]]; then
        print_info "✓ Test certificate issued successfully!"
        kubectl get certificate test-cert -n default
    else
        print_warning "Certificate not ready yet, checking status..."
        kubectl describe certificate test-cert -n default
    fi
}

verify_deployment() {
    print_header "Verifying Deployment"

    print_info "Checking Vault pods..."
    kubectl get pods -n vault -l app.kubernetes.io/name=vault

    print_info "Checking cert-manager pods..."
    kubectl get pods -n cert-manager

    print_info "Checking ClusterIssuer..."
    kubectl get clusterissuer

    print_info "Checking Vault status..."
    kubectl exec -n vault vault-0 -- vault status || true
}

main() {
    print_header "Phase 2: Certificates Setup"
    print_info "This script will deploy Vault and cert-manager"
    echo ""

    check_prerequisites
    load_config

    echo ""
    print_info "The following components will be deployed:"
    echo "  - HashiCorp Vault (HA mode, 3 replicas)"
    echo "  - Vault PKI secrets engine"
    echo "  - cert-manager"
    echo "  - Vault ClusterIssuer"
    echo ""

    read -p "Proceed with setup? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_warning "Setup cancelled"
        exit 0
    fi

    # Execute setup steps
    install_vault
    initialize_vault
    unseal_vault
    configure_vault_pki
    configure_vault_k8s_auth
    install_cert_manager
    create_vault_issuer
    test_certificate
    verify_deployment

    print_header "Phase 2 Complete!"
    print_info "Vault and cert-manager are ready"
    print_warning "IMPORTANT: Save the vault-keys.json file securely!"
    print_info "Next: Proceed to Phase 3 (CockroachDB Operator)"
}

# Run main function
main "$@"
