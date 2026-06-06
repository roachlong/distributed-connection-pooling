#!/bin/bash
set -e

#######################################
# EKS Reference Architecture Teardown
#######################################
# Removes deployed resources in reverse order
# Usage:
#   ./teardown.sh --phase 5          # Delete Phase 5 only
#   ./teardown.sh --from-phase 5     # Delete Phases 5-1 (reverse order)
#   ./teardown.sh --all              # Delete all phases (11-1)
#   ./teardown.sh --cluster-only     # Delete EKS cluster only (fast cleanup)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

#######################################
# Functions
#######################################

print_header() {
    echo -e "\n${GREEN}===================================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${GREEN}===================================================${NC}\n"
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

confirm() {
    local prompt="$1"
    local default="${2:-n}"

    if [[ "$default" == "y" ]]; then
        read -p "$prompt [Y/n]: " response
        response=${response:-y}
    else
        read -p "$prompt [y/N]: " response
        response=${response:-n}
    fi

    [[ "$response" =~ ^[Yy]$ ]]
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    print_info "Loading configuration from $CONFIG_FILE"
    source "$CONFIG_FILE"

    # Verify required variables
    if [[ -z "$AWS_ACCOUNT_ID" || -z "$AWS_PROFILE" || -z "$AWS_REGION_EAST" ]]; then
        print_error "Missing required variables in config.env"
        exit 1
    fi
}

#######################################
# Phase Teardown Functions
#######################################

teardown_phase_11() {
    print_header "Phase 11: GitOps / ArgoCD"

    if ! kubectl get namespace argocd &>/dev/null; then
        print_info "ArgoCD not installed, skipping"
        return 0
    fi

    print_info "Deleting ArgoCD applications..."
    kubectl delete applications --all -n argocd 2>/dev/null || true

    print_info "Deleting ArgoCD..."
    kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml 2>/dev/null || true
    kubectl delete namespace argocd --wait=false 2>/dev/null || true

    print_info "Phase 11 teardown complete"
}

teardown_phase_10() {
    print_header "Phase 10: Physical Cluster Replication (PCR)"

    print_info "Stopping PCR replication..."
    kubectl exec -it cockroachdb-east-0 -n cockroachdb -- \
        cockroach sql --certs-dir=/cockroach/cockroach-certs \
        -e "ALTER VIRTUAL CLUSTER main STOP SERVICE;" 2>/dev/null || true

    if [[ -n "$CLUSTER_NAME_WEST" ]]; then
        print_warning "Deleting West region cluster: ${CLUSTER_NAME_WEST}"
        if confirm "Delete West region EKS cluster?"; then
            eksctl delete cluster --name "${CLUSTER_NAME_WEST}" --region "${AWS_REGION_WEST}" --profile "${AWS_PROFILE}" --wait
            print_info "West cluster deleted"
        fi
    fi

    print_info "Phase 10 teardown complete"
}

teardown_phase_9() {
    print_header "Phase 9: Audit Logging"

    if [[ -d "${SCRIPT_DIR}/manifests/phase9-audit" ]]; then
        print_info "Deleting Fluent Bit resources..."
        kubectl delete -f "${SCRIPT_DIR}/manifests/phase9-audit/" 2>/dev/null || true
    fi

    print_info "Deleting logging namespace..."
    kubectl delete namespace logging --wait=false 2>/dev/null || true

    print_info "Deleting Fluent Bit IRSA..."
    eksctl delete iamserviceaccount \
        --cluster="${CLUSTER_NAME_EAST}" \
        --name=fluent-bit \
        --namespace=logging \
        --region="${AWS_REGION_EAST}" \
        --profile="${AWS_PROFILE}" 2>/dev/null || true

    print_info "Phase 9 teardown complete"
}

teardown_phase_8() {
    print_header "Phase 8: Security (Network Policies & IRSA)"

    if [[ -d "${SCRIPT_DIR}/manifests/phase8-security" ]]; then
        print_info "Deleting network policies..."
        kubectl delete -f "${SCRIPT_DIR}/manifests/phase8-security/" 2>/dev/null || true
    fi

    print_info "Deleting CRDB backup IRSA..."
    eksctl delete iamserviceaccount \
        --cluster="${CLUSTER_NAME_EAST}" \
        --name=cockroachdb-backup \
        --namespace=cockroachdb \
        --region="${AWS_REGION_EAST}" \
        --profile="${AWS_PROFILE}" 2>/dev/null || true

    print_info "Phase 8 teardown complete"
}

teardown_phase_7() {
    print_header "Phase 7: Observability (Prometheus & Grafana)"

    if helm list -n monitoring 2>/dev/null | grep -q kube-prometheus-stack; then
        print_info "Uninstalling kube-prometheus-stack..."
        helm uninstall kube-prometheus-stack -n monitoring
    fi

    print_info "Deleting monitoring namespace..."
    kubectl delete namespace monitoring --wait=false 2>/dev/null || true

    print_info "Phase 7 teardown complete"
}

teardown_phase_6() {
    print_header "Phase 6: Enterprise Features"

    if helm list -n external-secrets-system 2>/dev/null | grep -q external-secrets; then
        print_info "Uninstalling External Secrets Operator..."
        helm uninstall external-secrets -n external-secrets-system
    fi

    print_info "Deleting external-secrets-system namespace..."
    kubectl delete namespace external-secrets-system --wait=false 2>/dev/null || true

    print_info "Phase 6 teardown complete"
}

teardown_phase_5() {
    print_header "Phase 5: PgBouncer"

    if [[ -d "${SCRIPT_DIR}/manifests/phase5-pgbouncer" ]]; then
        print_info "Deleting PgBouncer resources..."
        kubectl delete -f "${SCRIPT_DIR}/manifests/phase5-pgbouncer/" 2>/dev/null || true
    fi

    print_info "Phase 5 teardown complete"
}

teardown_phase_4() {
    print_header "Phase 4: CockroachDB Cluster"

    if [[ -d "${SCRIPT_DIR}/manifests/phase4-crdb-cluster" ]]; then
        print_info "Deleting CockroachDB cluster..."
        kubectl delete -f "${SCRIPT_DIR}/manifests/phase4-crdb-cluster/crdb-east.yaml" 2>/dev/null || true

        print_info "Waiting for StatefulSet cleanup..."
        sleep 10
    fi

    print_info "Deleting cockroachdb namespace..."
    kubectl delete namespace cockroachdb --wait=false 2>/dev/null || true

    print_info "Phase 4 teardown complete"
}

teardown_phase_3() {
    print_header "Phase 3: CockroachDB Operator"

    if [[ -d "${SCRIPT_DIR}/manifests/phase3-operator" ]]; then
        print_info "Deleting CockroachDB Operator..."
        kubectl delete -f "${SCRIPT_DIR}/manifests/phase3-operator/operator.yaml" 2>/dev/null || true
    fi

    print_info "Deleting operator namespace..."
    kubectl delete namespace cockroach-operator-system --wait=false 2>/dev/null || true

    print_info "Phase 3 teardown complete"
}

teardown_phase_2() {
    print_header "Phase 2: Certificates (cert-manager)"

    if helm list -n cert-manager 2>/dev/null | grep -q cert-manager; then
        print_info "Uninstalling cert-manager..."
        helm uninstall cert-manager -n cert-manager
    fi

    print_info "Deleting cert-manager namespace..."
    kubectl delete namespace cert-manager --wait=false 2>/dev/null || true

    print_info "Deleting cert-manager CRDs..."
    kubectl delete crd \
        certificaterequests.cert-manager.io \
        certificates.cert-manager.io \
        challenges.acme.cert-manager.io \
        clusterissuers.cert-manager.io \
        issuers.cert-manager.io \
        orders.acme.cert-manager.io 2>/dev/null || true

    print_info "Phase 2 teardown complete"
}

teardown_phase_1() {
    print_header "Phase 1: Foundation (EKS Cluster, S3, KMS)"

    print_warning "This will delete the EKS cluster and all associated resources"
    print_warning "Cluster: ${CLUSTER_NAME_EAST}"
    print_warning "Region: ${AWS_REGION_EAST}"

    if ! confirm "Delete EKS cluster ${CLUSTER_NAME_EAST}?" "n"; then
        print_info "Skipping EKS cluster deletion"
        return 0
    fi

    # Clean up Phase 1 Kubernetes resources before deleting cluster
    print_info "Cleaning up Phase 1 resources..."

    # Delete test PVCs if they exist
    kubectl delete pvc test-pvc-phase1 2>/dev/null || true

    # Delete StorageClass
    kubectl delete storageclass crdb-gp3-encrypted 2>/dev/null || true
    kubectl delete storageclass gp2 2>/dev/null || true

    # Uninstall AWS Load Balancer Controller
    helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true

    # Delete IRSA for LB controller
    eksctl delete iamserviceaccount \
        --cluster="${CLUSTER_NAME_EAST}" \
        --name=aws-load-balancer-controller \
        --namespace=kube-system \
        --region="${AWS_REGION_EAST}" \
        --profile="${AWS_PROFILE}" 2>/dev/null || true

    # Delete IAM policy for LB controller
    POLICY_NAME="eksctl-${CLUSTER_NAME_EAST}-aws-load-balancer-controller"
    POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
    aws iam delete-policy --policy-arn "${POLICY_ARN}" --profile "${AWS_PROFILE}" 2>/dev/null || true

    print_info "Deleting EKS cluster (this may take 10-15 minutes)..."
    if eksctl delete cluster \
        --name "${CLUSTER_NAME_EAST}" \
        --region "${AWS_REGION_EAST}" \
        --profile "${AWS_PROFILE}" \
        --wait 2>&1; then
        print_info "EKS cluster deleted successfully"
    else
        print_warning "EKS cluster does not exist or failed to delete (continuing with S3/KMS cleanup)"
    fi

    print_info "Deleting S3 buckets..."
    if [[ -n "$S3_BUCKET_BACKUPS_EAST" ]]; then
        print_info "Emptying backup bucket: ${S3_BUCKET_BACKUPS_EAST}"
        aws s3 rm s3://${S3_BUCKET_BACKUPS_EAST} --recursive --profile "${AWS_PROFILE}" 2>/dev/null || true
        aws s3 rb s3://${S3_BUCKET_BACKUPS_EAST} --force --profile "${AWS_PROFILE}" 2>/dev/null || true
    fi

    if [[ -n "$S3_BUCKET_AUDIT_EAST" ]]; then
        print_info "Emptying audit bucket: ${S3_BUCKET_AUDIT_EAST}"
        aws s3 rm s3://${S3_BUCKET_AUDIT_EAST} --recursive --profile "${AWS_PROFILE}" 2>/dev/null || true
        aws s3 rb s3://${S3_BUCKET_AUDIT_EAST} --force --profile "${AWS_PROFILE}" 2>/dev/null || true
    fi

    if [[ -n "$KMS_KEY_ARN_EAST" ]]; then
        print_info "Scheduling KMS key deletion (7-day waiting period)..."
        aws kms schedule-key-deletion \
            --key-id "${KMS_KEY_ARN_EAST}" \
            --pending-window-in-days 7 \
            --region "${AWS_REGION_EAST}" \
            --profile "${AWS_PROFILE}" 2>/dev/null || true
    fi

    print_info "Phase 1 teardown complete"
}

cluster_only_teardown() {
    print_header "Cluster-Only Teardown (Fast Cleanup)"

    print_warning "This will delete ONLY the EKS cluster"
    print_warning "S3 buckets and KMS keys will remain (manual cleanup required)"
    print_warning "Cluster: ${CLUSTER_NAME_EAST}"

    if ! confirm "Delete EKS cluster ${CLUSTER_NAME_EAST}?"; then
        print_error "Teardown cancelled"
        exit 0
    fi

    print_info "Deleting EKS cluster (this may take 10-15 minutes)..."
    if eksctl delete cluster \
        --name "${CLUSTER_NAME_EAST}" \
        --region "${AWS_REGION_EAST}" \
        --profile "${AWS_PROFILE}" \
        --wait 2>&1; then
        print_info "Cluster deleted successfully"
    else
        print_warning "Cluster does not exist or failed to delete"
        exit 1
    fi

    print_warning "Manual cleanup required:"
    echo "  - S3 buckets: ${S3_BUCKET_BACKUPS_EAST}, ${S3_BUCKET_AUDIT_EAST}"
    echo "  - KMS key: ${KMS_KEY_ARN_EAST}"
}

#######################################
# Main Logic
#######################################

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Teardown EKS reference architecture components.

Options:
    --phase N           Delete only Phase N
    --from-phase N      Delete Phases N through 1 (reverse order)
    --all               Delete all phases (11 through 1)
    --cluster-only      Delete only the EKS cluster (fast cleanup)
    -h, --help          Show this help message

Examples:
    $0 --phase 5                # Delete Phase 5 (PgBouncer) only
    $0 --from-phase 5           # Delete Phases 5, 4, 3, 2, 1
    $0 --all                    # Delete all phases
    $0 --cluster-only           # Quick cluster deletion (leaves S3/KMS)

EOF
    exit 1
}

# Parse arguments
PHASE=""
FROM_PHASE=""
ALL_PHASES=false
CLUSTER_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --phase)
            PHASE="$2"
            shift 2
            ;;
        --from-phase)
            FROM_PHASE="$2"
            shift 2
            ;;
        --all)
            ALL_PHASES=true
            shift
            ;;
        --cluster-only)
            CLUSTER_ONLY=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate arguments
if [[ -z "$PHASE" && -z "$FROM_PHASE" && "$ALL_PHASES" == false && "$CLUSTER_ONLY" == false ]]; then
    print_error "Must specify --phase, --from-phase, --all, or --cluster-only"
    usage
fi

# Load configuration
load_config

print_header "EKS Reference Architecture Teardown"
print_info "AWS Account: ${AWS_ACCOUNT_ID}"
print_info "AWS Profile: ${AWS_PROFILE}"
print_info "Region: ${AWS_REGION_EAST}"
print_info "Cluster: ${CLUSTER_NAME_EAST}"
echo ""

# Cluster-only mode
if [[ "$CLUSTER_ONLY" == true ]]; then
    cluster_only_teardown
    exit 0
fi

# Execute teardown based on options
if [[ -n "$PHASE" ]]; then
    # Single phase
    print_warning "Deleting Phase ${PHASE} only"
    if ! confirm "Continue?"; then
        print_error "Teardown cancelled"
        exit 0
    fi

    teardown_phase_${PHASE}

elif [[ -n "$FROM_PHASE" ]]; then
    # Range of phases (reverse order)
    print_warning "Deleting Phases ${FROM_PHASE} through 1 (reverse order)"
    if ! confirm "Continue?"; then
        print_error "Teardown cancelled"
        exit 0
    fi

    for ((i=FROM_PHASE; i>=1; i--)); do
        teardown_phase_${i}
    done

elif [[ "$ALL_PHASES" == true ]]; then
    # All phases
    print_warning "Deleting ALL phases (11 through 1)"
    print_warning "This will remove the entire deployment"
    if ! confirm "Are you sure?"; then
        print_error "Teardown cancelled"
        exit 0
    fi

    for i in {11..1}; do
        teardown_phase_${i}
    done
fi

print_header "Teardown Complete"
print_info "All requested resources have been deleted"
print_warning "Note: Some resources may take a few minutes to fully terminate"

# Check for orphaned resources
echo ""
print_info "Recommended: Check for orphaned resources:"
echo "  - EBS volumes: aws ec2 describe-volumes --region ${AWS_REGION_EAST}"
echo "  - Load Balancers: aws elbv2 describe-load-balancers --region ${AWS_REGION_EAST}"
echo "  - Security Groups: aws ec2 describe-security-groups --region ${AWS_REGION_EAST}"
