#!/usr/bin/env bash
# Phase 1: Foundation Setup Script
# This script guides you through the EKS cluster deployment with all configurable values

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/config.env"
GENERATED_DIR="${ROOT_DIR}/generated/phase1"

# Create generated directory if it doesn't exist
mkdir -p "${GENERATED_DIR}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function print_header() {
    echo -e "\n${GREEN}===================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${GREEN}===================================${NC}\n"
}

function print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

function print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

function print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

function check_prerequisites() {
    print_header "Checking Prerequisites"

    local missing=0

    # Check required tools
    for tool in aws eksctl kubectl envsubst jq; do
        if ! command -v $tool &> /dev/null; then
            print_error "$tool is not installed"
            missing=1
        else
            print_info "$tool is installed ($(command -v $tool))"
        fi
    done

    if [[ $missing -eq 1 ]]; then
        print_error "Missing required tools. Please install them and try again."
        exit 1
    fi

    print_info "All prerequisites met"
}

function load_config() {
    print_header "Loading Configuration"

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        print_error "Configuration file not found: ${CONFIG_FILE}"
        print_info "Please create config.env from the template"
        exit 1
    fi

    # Source the config file
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"

    print_info "Configuration loaded from ${CONFIG_FILE}"
    print_info "  Project: ${PROJECT_NAME}"
    print_info "  Region: ${AWS_REGION_EAST}"
    print_info "  Cluster: ${CLUSTER_NAME_EAST}"
}

function validate_config() {
    print_header "Validating Configuration"

    local errors=0

    # Check required variables
    if [[ -z "${AWS_ACCOUNT_ID}" ]]; then
        print_error "AWS_ACCOUNT_ID is not set"
        errors=1
    else
        print_info "AWS Account ID: ${AWS_ACCOUNT_ID}"
    fi

    if [[ -z "${AWS_REGION_EAST}" ]]; then
        print_error "AWS_REGION_EAST is not set"
        errors=1
    else
        print_info "AWS Region: ${AWS_REGION_EAST}"
    fi

    if [[ -z "${CLUSTER_NAME_EAST}" ]]; then
        print_error "CLUSTER_NAME_EAST is not set"
        errors=1
    else
        print_info "Cluster Name: ${CLUSTER_NAME_EAST}"
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity --profile "${AWS_PROFILE}" &> /dev/null; then
        print_error "AWS credentials not configured or profile ${AWS_PROFILE} not found"
        print_info "Run: aws sso login --profile ${AWS_PROFILE}"
        errors=1
    else
        CALLER_IDENTITY=$(aws sts get-caller-identity --profile "${AWS_PROFILE}")
        CALLER_ACCOUNT=$(echo "${CALLER_IDENTITY}" | jq -r '.Account')
        CALLER_ARN=$(echo "${CALLER_IDENTITY}" | jq -r '.Arn')
        print_info "AWS Credentials OK"
        print_info "  Account: ${CALLER_ACCOUNT}"
        print_info "  ARN: ${CALLER_ARN}"

        if [[ "${CALLER_ACCOUNT}" != "${AWS_ACCOUNT_ID}" ]]; then
            print_warning "AWS Account ID mismatch!"
            print_warning "  Config: ${AWS_ACCOUNT_ID}"
            print_warning "  Actual: ${CALLER_ACCOUNT}"
        fi
    fi

    if [[ $errors -eq 1 ]]; then
        print_error "Configuration validation failed"
        exit 1
    fi

    print_info "Configuration validated successfully"
}

function create_kms_key() {
    print_header "Creating KMS Customer-Managed Key"

    local key_created=false
    local original_key_arn="${KMS_KEY_ARN_EAST}"

    # Check if key alias exists
    if KEY_INFO=$(aws kms describe-key --key-id "${KMS_KEY_ALIAS_EAST}" --region "${AWS_REGION_EAST}" --profile "${AWS_PROFILE}" 2>/dev/null); then
        KEY_STATE=$(echo "${KEY_INFO}" | jq -r '.KeyMetadata.KeyState')
        KMS_KEY_ARN_EAST=$(echo "${KEY_INFO}" | jq -r '.KeyMetadata.Arn')

        if [[ "${KEY_STATE}" == "PendingDeletion" ]]; then
            print_warning "KMS key ${KMS_KEY_ALIAS_EAST} exists but is PendingDeletion"
            print_info "Deleting old alias and creating new key..."

            # Delete the alias so we can reuse it
            aws kms delete-alias \
                --alias-name "${KMS_KEY_ALIAS_EAST}" \
                --region "${AWS_REGION_EAST}" \
                --profile "${AWS_PROFILE}"

            print_info "Old alias deleted, creating new key..."
        else
            print_warning "KMS key ${KMS_KEY_ALIAS_EAST} already exists and is active"
            print_info "Using existing key: ${KMS_KEY_ARN_EAST}"
            export KMS_KEY_ARN_EAST
            return 0
        fi
    fi

    # Create new KMS key
    if true; then
        print_info "Creating new KMS key..."

        KEY_ID=$(aws kms create-key \
            --description "CockroachDB EBS encryption key - ${AWS_REGION_EAST}" \
            --region "${AWS_REGION_EAST}" \
            --profile "${AWS_PROFILE}" \
            --query 'KeyMetadata.KeyId' \
            --output text)

        print_info "Key created: ${KEY_ID}"

        # Create alias
        aws kms create-alias \
            --alias-name "${KMS_KEY_ALIAS_EAST}" \
            --target-key-id "${KEY_ID}" \
            --region "${AWS_REGION_EAST}" \
            --profile "${AWS_PROFILE}"

        print_info "Alias created: ${KMS_KEY_ALIAS_EAST}"

        KMS_KEY_ARN_EAST=$(aws kms describe-key --key-id "${KMS_KEY_ALIAS_EAST}" --region "${AWS_REGION_EAST}" --profile "${AWS_PROFILE}" --query 'KeyMetadata.Arn' --output text)
        print_info "KMS Key ARN: ${KMS_KEY_ARN_EAST}"

        key_created=true
    fi

    # Auto-update config.env if:
    # 1. We created a new key (not reusing existing)
    # 2. Original value in config.env was blank/empty
    if [[ "$key_created" == true ]] && [[ -z "$original_key_arn" ]]; then
        print_info "Auto-updating config.env with KMS_KEY_ARN_EAST..."
        sed -i '' "s|export KMS_KEY_ARN_EAST=\"\"|export KMS_KEY_ARN_EAST=\"${KMS_KEY_ARN_EAST}\"|" "${CONFIG_FILE}"
        print_info "Updated config.env: KMS_KEY_ARN_EAST=${KMS_KEY_ARN_EAST}"
    elif [[ "$key_created" == true ]]; then
        print_warning "Please update config.env with:"
        echo "export KMS_KEY_ARN_EAST=\"${KMS_KEY_ARN_EAST}\""
    fi

    # Export for use in this session
    export KMS_KEY_ARN_EAST
}

function create_s3_buckets() {
    print_header "Creating S3 Buckets with Object Lock"

    # Backup bucket
    if aws s3 ls "s3://${S3_BUCKET_BACKUPS_EAST}" --region "${AWS_REGION_EAST}" --profile "${AWS_PROFILE}" &> /dev/null 2>&1; then
        print_warning "Backup bucket ${S3_BUCKET_BACKUPS_EAST} already exists"
    else
        print_info "Creating backup bucket: ${S3_BUCKET_BACKUPS_EAST}"

        # us-east-1 doesn't accept LocationConstraint parameter
        if [[ "${AWS_REGION_EAST}" == "us-east-1" ]]; then
            aws s3api create-bucket \
                --bucket "${S3_BUCKET_BACKUPS_EAST}" \
                --region "${AWS_REGION_EAST}" \
                --object-lock-enabled-for-bucket \
                --profile "${AWS_PROFILE}"
        else
            aws s3api create-bucket \
                --bucket "${S3_BUCKET_BACKUPS_EAST}" \
                --region "${AWS_REGION_EAST}" \
                --create-bucket-configuration LocationConstraint="${AWS_REGION_EAST}" \
                --object-lock-enabled-for-bucket \
                --profile "${AWS_PROFILE}"
        fi

        # Configure Object Lock (365-day retention)
        aws s3api put-object-lock-configuration \
            --bucket "${S3_BUCKET_BACKUPS_EAST}" \
            --object-lock-configuration '{
                "ObjectLockEnabled": "Enabled",
                "Rule": {
                    "DefaultRetention": {
                        "Mode": "COMPLIANCE",
                        "Days": 365
                    }
                }
            }' \
            --region "${AWS_REGION_EAST}" \
            --profile "${AWS_PROFILE}"

        # Enable encryption
        aws s3api put-bucket-encryption \
            --bucket "${S3_BUCKET_BACKUPS_EAST}" \
            --server-side-encryption-configuration "{
                \"Rules\": [{
                    \"ApplyServerSideEncryptionByDefault\": {
                        \"SSEAlgorithm\": \"aws:kms\",
                        \"KMSMasterKeyID\": \"${KMS_KEY_ARN_EAST}\"
                    }
                }]
            }" \
            --region "${AWS_REGION_EAST}" \
            --profile "${AWS_PROFILE}"

        print_info "Backup bucket created with Object Lock and KMS encryption"
    fi

    # Audit log bucket
    if aws s3 ls "s3://${S3_BUCKET_AUDIT_EAST}" --region "${AWS_REGION_EAST}" --profile "${AWS_PROFILE}" &> /dev/null 2>&1; then
        print_warning "Audit bucket ${S3_BUCKET_AUDIT_EAST} already exists"
    else
        print_info "Creating audit log bucket: ${S3_BUCKET_AUDIT_EAST}"

        # us-east-1 doesn't accept LocationConstraint parameter
        if [[ "${AWS_REGION_EAST}" == "us-east-1" ]]; then
            aws s3api create-bucket \
                --bucket "${S3_BUCKET_AUDIT_EAST}" \
                --region "${AWS_REGION_EAST}" \
                --object-lock-enabled-for-bucket \
                --profile "${AWS_PROFILE}"
        else
            aws s3api create-bucket \
                --bucket "${S3_BUCKET_AUDIT_EAST}" \
                --region "${AWS_REGION_EAST}" \
                --create-bucket-configuration LocationConstraint="${AWS_REGION_EAST}" \
                --object-lock-enabled-for-bucket \
                --profile "${AWS_PROFILE}"
        fi

        # Configure Object Lock (7-year / 2555-day retention)
        aws s3api put-object-lock-configuration \
            --bucket "${S3_BUCKET_AUDIT_EAST}" \
            --object-lock-configuration '{
                "ObjectLockEnabled": "Enabled",
                "Rule": {
                    "DefaultRetention": {
                        "Mode": "COMPLIANCE",
                        "Days": 2555
                    }
                }
            }' \
            --region "${AWS_REGION_EAST}" \
            --profile "${AWS_PROFILE}"

        # Enable encryption
        aws s3api put-bucket-encryption \
            --bucket "${S3_BUCKET_AUDIT_EAST}" \
            --server-side-encryption-configuration "{
                \"Rules\": [{
                    \"ApplyServerSideEncryptionByDefault\": {
                        \"SSEAlgorithm\": \"aws:kms\",
                        \"KMSMasterKeyID\": \"${KMS_KEY_ARN_EAST}\"
                    }
                }]
            }" \
            --region "${AWS_REGION_EAST}" \
            --profile "${AWS_PROFILE}"

        print_info "Audit log bucket created with 7-year Object Lock and KMS encryption"
    fi
}

function mirror_images() {
    # Skip image mirroring for commercial AWS (can pull directly from public registries)
    if [[ "${AWS_REGION_EAST}" != us-gov-* ]]; then
        print_header "Container Images"
        print_info "Commercial AWS detected - skipping image mirroring"
        print_info "Images will be pulled directly from public registries (Docker Hub, public.ecr.aws)"
        return 0
    fi

    # GovCloud: Require image mirroring
    print_header "Container Image Mirroring to GovCloud ECR"

    print_warning "This step requires manual intervention"
    print_info "You need to mirror the following images to ${ECR_REGISTRY_EAST}:"
    echo ""
    echo "  - cockroachdb/cockroach:${COCKROACHDB_VERSION}"
    echo "  - cockroachdb/cockroach-operator:${COCKROACHDB_OPERATOR_VERSION}"
    echo "  - pgbouncer/pgbouncer:${PGBOUNCER_VERSION}"
    echo "  - fluent/fluent-bit:${FLUENT_BIT_VERSION}"
    echo "  - jetstack/cert-manager-controller:${CERT_MANAGER_VERSION}"
    echo "  - jetstack/cert-manager-webhook:${CERT_MANAGER_VERSION}"
    echo "  - jetstack/cert-manager-cainjector:${CERT_MANAGER_VERSION}"
    echo "  - external-secrets/external-secrets:${EXTERNAL_SECRETS_VERSION}"
    echo "  - hashicorp/vault-k8s:${VAULT_K8S_VERSION}"
    echo ""
    print_info "Refer to DEPLOYMENT.md 'GovCloud ECR Mirroring' section for mirroring commands"
    echo ""
    read -p "Have you mirrored all images? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_error "Please mirror images before proceeding"
        exit 1
    fi
}

function deploy_eks_cluster() {
    print_header "Deploying EKS Cluster"

    # Check if cluster already exists
    if aws eks describe-cluster --name "${CLUSTER_NAME_EAST}" --region "${AWS_REGION_EAST}" --profile "${AWS_PROFILE}" &>/dev/null; then
        print_warning "Cluster ${CLUSTER_NAME_EAST} already exists"
        print_info "Updating kubeconfig..."
        aws eks update-kubeconfig --name "${CLUSTER_NAME_EAST}" --region "${AWS_REGION_EAST}" --profile "${AWS_PROFILE}"
        print_info "Kubeconfig updated. You can now use kubectl"
        return 0
    fi

    # Generate cluster config with environment variables substituted
    print_info "Generating cluster configuration..."
    envsubst < "${SCRIPT_DIR}/cluster-east.yaml" > "${GENERATED_DIR}/cluster-east.yaml"

    print_info "Cluster configuration generated: ${GENERATED_DIR}/cluster-east.yaml"
    print_info "Review the configuration before proceeding"

    read -p "Deploy EKS cluster ${CLUSTER_NAME_EAST}? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_warning "Deployment cancelled"
        exit 0
    fi

    print_info "Creating EKS cluster (this will take 15-20 minutes)..."

    # Run eksctl and capture exit code (don't exit on error)
    set +e
    eksctl create cluster -f "${GENERATED_DIR}/cluster-east.yaml" --profile "${AWS_PROFILE}"
    local eksctl_exit_code=$?
    set -e

    # Verify cluster was actually created (eksctl sometimes fails on node watcher but cluster succeeds)
    if aws eks describe-cluster --name "${CLUSTER_NAME_EAST}" --region "${AWS_REGION_EAST}" --profile "${AWS_PROFILE}" &>/dev/null; then
        print_info "EKS cluster created successfully"

        # Update kubeconfig
        print_info "Updating kubeconfig..."
        aws eks update-kubeconfig --name "${CLUSTER_NAME_EAST}" --region "${AWS_REGION_EAST}" --profile "${AWS_PROFILE}"

        print_info "Kubeconfig updated. You can now use kubectl"

        # Wait for nodes to be ready
        print_info "Waiting for nodes to be ready..."
        local ready_nodes=0
        local expected_nodes=6  # 3 CRDB nodes + 3 app nodes

        for i in {1..30}; do
            ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready" || echo "0")
            if [[ $ready_nodes -ge $expected_nodes ]]; then
                print_info "All $ready_nodes nodes are ready"
                break
            fi
            echo "  Waiting for nodes ($ready_nodes/$expected_nodes ready)..."
            sleep 10
        done

        if [[ $ready_nodes -lt $expected_nodes ]]; then
            print_warning "Only $ready_nodes/$expected_nodes nodes ready, but continuing..."
        fi
    else
        print_error "Cluster creation failed"
        exit 1
    fi
}

function install_ebs_csi_driver() {
    print_header "Installing AWS EBS CSI Driver"

    # Check if addon already exists
    if eksctl get addon --cluster="${CLUSTER_NAME_EAST}" --region="${AWS_REGION_EAST}" --profile="${AWS_PROFILE}" --name aws-ebs-csi-driver &>/dev/null 2>&1; then
        print_warning "EBS CSI driver addon already installed"
        return 0
    fi

    # Create IAM role for EBS CSI driver
    print_info "Creating IAM role for EBS CSI driver..."
    set +e
    eksctl create iamserviceaccount \
        --cluster="${CLUSTER_NAME_EAST}" \
        --name=ebs-csi-controller-sa \
        --namespace=kube-system \
        --attach-policy-arn=arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
        --override-existing-serviceaccounts \
        --region="${AWS_REGION_EAST}" \
        --profile="${AWS_PROFILE}" \
        --approve 2>&1 | grep -v "certificate signed by unknown authority" || true
    set -e

    # Get the IAM role ARN
    print_info "Getting IAM role ARN..."
    STACK_NAME="eksctl-${CLUSTER_NAME_EAST}-addon-iamserviceaccount-kube-system-ebs-csi-controller-sa"
    EBS_CSI_ROLE_ARN=$(aws cloudformation describe-stack-resources \
        --stack-name "${STACK_NAME}" \
        --region "${AWS_REGION_EAST}" \
        --profile "${AWS_PROFILE}" \
        --query 'StackResources[?ResourceType==`AWS::IAM::Role`].PhysicalResourceId' \
        --output text 2>/dev/null || echo "")

    if [[ -n "$EBS_CSI_ROLE_ARN" ]]; then
        # Get full ARN
        EBS_CSI_ROLE_ARN=$(aws iam get-role --role-name "${EBS_CSI_ROLE_ARN}" --profile "${AWS_PROFILE}" --query 'Role.Arn' --output text)
        print_info "EBS CSI IAM role: ${EBS_CSI_ROLE_ARN}"
    else
        print_error "Failed to create IAM role for EBS CSI driver"
        exit 1
    fi

    # Install EBS CSI driver addon
    print_info "Installing EBS CSI driver addon..."
    eksctl create addon \
        --cluster="${CLUSTER_NAME_EAST}" \
        --name=aws-ebs-csi-driver \
        --service-account-role-arn="${EBS_CSI_ROLE_ARN}" \
        --region="${AWS_REGION_EAST}" \
        --profile="${AWS_PROFILE}" \
        --force

    # Wait for addon to be active
    print_info "Waiting for EBS CSI driver to be active..."
    for i in {1..30}; do
        ADDON_STATUS=$(eksctl get addon --cluster="${CLUSTER_NAME_EAST}" --region="${AWS_REGION_EAST}" --profile="${AWS_PROFILE}" --name aws-ebs-csi-driver -o json 2>/dev/null | jq -r '.[0].Status' || echo "")
        if [[ "$ADDON_STATUS" == "ACTIVE" ]]; then
            print_info "EBS CSI driver is active"
            break
        fi
        echo "  Waiting for EBS CSI driver... ($i/30)"
        sleep 10
    done

    # Verify pods are running
    print_info "Verifying EBS CSI driver pods..."
    kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=aws-ebs-csi-driver -n kube-system --timeout=120s || print_warning "Some EBS CSI pods may still be starting"

    # Grant EBS CSI driver role permission to use KMS key
    if [[ -n "$KMS_KEY_ARN_EAST" ]]; then
        print_info "Granting EBS CSI driver permission to use KMS key..."
        aws kms create-grant \
            --key-id "${KMS_KEY_ARN_EAST}" \
            --grantee-principal "${EBS_CSI_ROLE_ARN}" \
            --operations Decrypt Encrypt GenerateDataKey GenerateDataKeyWithoutPlaintext CreateGrant DescribeKey \
            --region "${AWS_REGION_EAST}" \
            --profile "${AWS_PROFILE}" >/dev/null || print_warning "KMS grant may already exist"
        print_info "KMS grant created for EBS CSI driver"
    fi

    print_info "EBS CSI driver installed successfully"
}

function install_lb_controller() {
    print_header "Installing AWS Load Balancer Controller"

    # Create IAM policy
    print_info "Creating IAM policy for LB controller..."

    # Try to download the policy, fall back to curl --insecure if SSL fails
    if ! curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json 2>/dev/null; then
        print_warning "Secure download failed, trying with --insecure (corporate proxy detected)"
        curl --insecure -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json
    fi

    # Determine ARN format based on region (commercial vs GovCloud)
    if [[ "${AWS_REGION_EAST}" == us-gov-* ]]; then
        IAM_ARN_PREFIX="arn:aws-us-gov"
    else
        IAM_ARN_PREFIX="arn:aws"
    fi

    # Use eksctl- prefix to match IAM permissions boundary requirements
    POLICY_NAME="eksctl-${CLUSTER_NAME_EAST}-aws-load-balancer-controller"
    POLICY_ARN="${IAM_ARN_PREFIX}:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"

    if ! aws iam get-policy --policy-arn "${POLICY_ARN}" --profile "${AWS_PROFILE}" &> /dev/null; then
        aws iam create-policy \
            --policy-name "${POLICY_NAME}" \
            --policy-document file://iam-policy.json \
            --region "${AWS_REGION_EAST}" \
            --profile "${AWS_PROFILE}"
        print_info "IAM policy created: ${POLICY_NAME}"
    else
        print_warning "IAM policy already exists"
    fi

    rm -f iam-policy.json

    # Create IRSA
    print_info "Creating IAM role for service account..."
    set +e
    eksctl create iamserviceaccount \
        --cluster="${CLUSTER_NAME_EAST}" \
        --namespace=kube-system \
        --name=aws-load-balancer-controller \
        --attach-policy-arn="${POLICY_ARN}" \
        --override-existing-serviceaccounts \
        --region "${AWS_REGION_EAST}" \
        --profile "${AWS_PROFILE}" \
        --approve 2>&1 | grep -v "certificate signed by unknown authority" || true
    set -e

    # Verify service account was created, if not create it manually
    if ! kubectl get serviceaccount aws-load-balancer-controller -n kube-system &>/dev/null; then
        print_warning "Service account not created by eksctl (TLS timing issue), creating manually..."

        # Get the IAM role ARN from CloudFormation stack
        STACK_NAME="eksctl-${CLUSTER_NAME_EAST}-addon-iamserviceaccount-kube-system-aws-load-balancer-controller"
        ROLE_ARN=$(aws cloudformation describe-stack-resources \
            --stack-name "${STACK_NAME}" \
            --region "${AWS_REGION_EAST}" \
            --profile "${AWS_PROFILE}" \
            --query 'StackResources[?ResourceType==`AWS::IAM::Role`].PhysicalResourceId' \
            --output text 2>/dev/null || echo "")

        if [[ -n "$ROLE_ARN" ]]; then
            # Get full ARN format
            ROLE_ARN=$(aws iam get-role --role-name "${ROLE_ARN}" --profile "${AWS_PROFILE}" --query 'Role.Arn' --output text)

            # Create service account with IRSA annotation
            cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: ${ROLE_ARN}
EOF
            print_info "Service account created manually with IRSA role: ${ROLE_ARN}"
        else
            print_warning "Could not find IAM role, proceeding anyway (may already exist)"
        fi
    else
        print_info "Service account verified"
    fi

    # Install controller via Helm
    print_info "Installing LB controller via Helm..."
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update

    helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n kube-system \
        --set clusterName="${CLUSTER_NAME_EAST}" \
        --set serviceAccount.create=false \
        --set serviceAccount.name=aws-load-balancer-controller \
        --set region="${AWS_REGION_EAST}" \
        --set vpcId="$(aws eks describe-cluster --name "${CLUSTER_NAME_EAST}" --region "${AWS_REGION_EAST}" --profile "${AWS_PROFILE}" --query 'cluster.resourcesVpcConfig.vpcId' --output text)" \
        || print_warning "LB controller may already be installed"

    # Wait for deployment to be ready (restart if needed due to service account timing)
    print_info "Waiting for LB controller pods to be ready..."
    sleep 10

    # Check if pods are running, if not restart deployment to pick up service account
    READY_PODS=$(kubectl get deployment aws-load-balancer-controller -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "$READY_PODS" == "0" ]]; then
        print_info "Restarting deployment to pick up service account..."
        kubectl rollout restart deployment/aws-load-balancer-controller -n kube-system
        kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s
    fi

    print_info "AWS Load Balancer Controller installed"
}

function create_storageclass() {
    print_header "Creating StorageClass with Customer-Managed KMS Key"

    # Check if StorageClass already exists
    if kubectl get storageclass "${STORAGE_CLASS_NAME}" &>/dev/null; then
        print_warning "StorageClass ${STORAGE_CLASS_NAME} already exists"
        return 0
    fi

    # Generate StorageClass manifest
    print_info "Generating StorageClass manifest..."
    envsubst < "${SCRIPT_DIR}/storageclass.yaml.template" > "${GENERATED_DIR}/storageclass.yaml"

    # Apply StorageClass
    print_info "Creating StorageClass: ${STORAGE_CLASS_NAME}"
    kubectl apply -f "${GENERATED_DIR}/storageclass.yaml"

    print_info "StorageClass created successfully"
}

function verify_deployment() {
    print_header "Verifying Deployment"

    print_info "Checking nodes..."
    kubectl get nodes -L topology.kubernetes.io/zone

    print_info "Checking node groups..."
    eksctl get nodegroup --cluster="${CLUSTER_NAME_EAST}" --region "${AWS_REGION_EAST}" --profile "${AWS_PROFILE}"

    print_info "Checking StorageClass..."
    kubectl get storageclass "${STORAGE_CLASS_NAME}"

    print_info "Checking AWS LB Controller..."
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

    print_info "Creating test PVC..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc-phase1
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${STORAGE_CLASS_NAME}
  resources:
    requests:
      storage: 10Gi
EOF

    sleep 5
    kubectl get pvc test-pvc-phase1

    print_warning "Note: PVC will stay Pending until a pod is scheduled (WaitForFirstConsumer)"

    read -p "Delete test PVC? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kubectl delete pvc test-pvc-phase1
        print_info "Test PVC deleted"
    fi
}

function main() {
    print_header "Phase 1: Foundation Setup"
    print_info "This script will set up the EKS cluster infrastructure"
    echo ""

    check_prerequisites
    load_config
    validate_config

    echo ""
    print_info "The following resources will be created:"
    echo "  - KMS Customer-Managed Key for EBS encryption"
    echo "  - S3 buckets (backups + audit logs) with Object Lock"
    echo "  - EKS cluster: ${CLUSTER_NAME_EAST} in ${AWS_REGION_EAST}"
    echo "  - 3 CockroachDB node groups (one per AZ)"
    echo "  - 1 Application node group (multi-AZ)"
    echo "  - AWS EBS CSI Driver (for persistent volumes)"
    echo "  - AWS Load Balancer Controller"
    echo "  - StorageClass: ${STORAGE_CLASS_NAME}"
    echo ""

    read -p "Proceed with setup? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_warning "Setup cancelled"
        exit 0
    fi

    # Execute setup steps
    create_kms_key
    create_s3_buckets
    mirror_images
    deploy_eks_cluster
    install_ebs_csi_driver
    install_lb_controller
    create_storageclass
    verify_deployment

    print_header "Phase 1 Complete!"
    print_info "EKS cluster is ready"
    print_info "Next: Proceed to Phase 2 (Certificates)"
}

# Run main function
main "$@"
