# Phase 1: Foundation

Deploy EKS cluster with 3-AZ topology, networking, and storage infrastructure.

## Prerequisites

- AWS credentials configured (commercial AWS or GovCloud)
- Tools installed: `aws`, `eksctl`, `kubectl`, `helm`, `jq`, `envsubst`
- Container images available:
  - **Commercial AWS**: Pull directly from public registries (no setup required)
  - **GovCloud**: Mirror images to private ECR (see [DEPLOYMENT.md](../../DEPLOYMENT.md#govcloud-ecr-mirroring))

## Configuration

All values are configured in `../../config.env`. **No hard-coded values**.

### Step 1: Configure Your Environment

Edit `kubernetes/eks/config.env` with your specific values:

```bash
# Open config.env in your editor
vim ../../config.env
```

**Required Configuration Changes**:

1. **AWS Account & Authentication**:
   ```bash
   export AWS_ACCOUNT_ID="123456789012"  # Your AWS account ID
   export AWS_PROFILE="default"  # Your AWS CLI profile name
   # For GovCloud: export AWS_PROFILE="govcloud-revenue"
   ```

2. **Regions** (commercial AWS by default):
   ```bash
   export AWS_REGION_EAST="us-east-1"
   export AWS_REGION_WEST="us-west-2"
   # For GovCloud: us-gov-east-1 / us-gov-west-1
   ```

3. **Project Naming**:
   ```bash
   export PROJECT_NAME="crdb-dcp"
   export ENVIRONMENT="production"  # or "development", "staging"
   # For GovCloud: export ENVIRONMENT="govcloud"
   ```

4. **Node Configuration** (adjust sizes as needed):
   ```bash
   export CRDB_NODE_INSTANCE_TYPE="m5.2xlarge"
   export APP_NODE_INSTANCE_TYPE="c5.xlarge"
   ```

5. **IAM Permissions Boundary** (if required by your organization):
   ```bash
   # Usually not required in commercial AWS unless org policy mandates it
   export IAM_PERMISSIONS_BOUNDARY_ARN=""
   # For GovCloud or orgs with boundary requirement:
   # export IAM_PERMISSIONS_BOUNDARY_ARN="arn:aws-us-gov:iam::123456789012:policy/YourBoundary"
   ```

6. **HashiCorp Vault** (if you have Vault already):
   ```bash
   export VAULT_ADDR="https://vault.example.com:8200"
   ```

7. **Monitoring** (change default Grafana password!):
   ```bash
   export GRAFANA_ADMIN_PASSWORD="changeme"  # Change this!
   ```

### Step 2: Source Configuration

```bash
# Navigate to EKS directory
cd kubernetes/eks

# Source the configuration
source config.env

# Verify variables are set
echo "Account ID: $AWS_ACCOUNT_ID"
echo "Region: $AWS_REGION_EAST"
echo "Cluster: $CLUSTER_NAME_EAST"
```

## Deployment Options

### Option 1: Automated Setup (Recommended)

Use the provided setup script that guides you through each step:

```bash
cd manifests/phase1-foundation
./setup.sh
```

The script will:
1. Check prerequisites
2. Validate configuration
3. Create KMS customer-managed key
4. Create S3 buckets with Object Lock
5. Prompt for image mirroring confirmation (GovCloud only - skippable for commercial AWS)
6. Deploy EKS cluster
7. Install AWS Load Balancer Controller
8. Create StorageClass
9. Verify deployment

### Option 2: Manual Step-by-Step

If you prefer manual control:

#### 1. Create KMS Key

```bash
source ../../config.env

# Create key
KEY_ID=$(aws kms create-key \
  --description "CockroachDB EBS encryption key - ${AWS_REGION_EAST}" \
  --region "${AWS_REGION_EAST}" \
  --profile "${AWS_PROFILE}" \
  --query 'KeyMetadata.KeyId' \
  --output text)

# Create alias
aws kms create-alias \
  --alias-name "${KMS_KEY_ALIAS_EAST}" \
  --target-key-id "${KEY_ID}" \
  --region "${AWS_REGION_EAST}" \
  --profile "${AWS_PROFILE}"

# Get ARN and update config.env
export KMS_KEY_ARN_EAST=$(aws kms describe-key \
  --key-id "${KMS_KEY_ALIAS_EAST}" \
  --region "${AWS_REGION_EAST}" \
  --profile "${AWS_PROFILE}" \
  --query 'KeyMetadata.Arn' \
  --output text)

echo "Update config.env with: export KMS_KEY_ARN_EAST=\"${KMS_KEY_ARN_EAST}\""
```

#### 2. Create S3 Buckets

```bash
# Backup bucket (365-day retention)
aws s3api create-bucket \
  --bucket "${S3_BUCKET_BACKUPS_EAST}" \
  --region "${AWS_REGION_EAST}" \
  --create-bucket-configuration LocationConstraint="${AWS_REGION_EAST}" \
  --object-lock-enabled-for-bucket \
  --profile "${AWS_PROFILE}"

aws s3api put-object-lock-configuration \
  --bucket "${S3_BUCKET_BACKUPS_EAST}" \
  --object-lock-configuration 'Rule={DefaultRetention={Mode=COMPLIANCE,Days=365}}' \
  --region "${AWS_REGION_EAST}" \
  --profile "${AWS_PROFILE}"

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

# Audit log bucket (7-year retention)
aws s3api create-bucket \
  --bucket "${S3_BUCKET_AUDIT_EAST}" \
  --region "${AWS_REGION_EAST}" \
  --create-bucket-configuration LocationConstraint="${AWS_REGION_EAST}" \
  --object-lock-enabled-for-bucket \
  --profile "${AWS_PROFILE}"

aws s3api put-object-lock-configuration \
  --bucket "${S3_BUCKET_AUDIT_EAST}" \
  --object-lock-configuration 'Rule={DefaultRetention={Mode=COMPLIANCE,Days=2555}}' \
  --region "${AWS_REGION_EAST}" \
  --profile "${AWS_PROFILE}"

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
```

#### 3. Container Images

**Commercial AWS**: Skip this step - images will be pulled directly from public registries.

**GovCloud only**: Mirror images to private ECR. See [DEPLOYMENT.md](../../DEPLOYMENT.md#govcloud-ecr-mirroring) for detailed commands.

#### 4. Deploy EKS Cluster

```bash
# Generate cluster config with your variables
envsubst < cluster-east.yaml > cluster-east.generated.yaml

# Review generated config
cat cluster-east.generated.yaml

# Deploy cluster (takes 15-20 minutes)
eksctl create cluster -f cluster-east.generated.yaml --profile "${AWS_PROFILE}"

# Update kubeconfig
aws eks update-kubeconfig \
  --name "${CLUSTER_NAME_EAST}" \
  --region "${AWS_REGION_EAST}" \
  --profile "${AWS_PROFILE}"
```

#### 5. Install AWS Load Balancer Controller

```bash
# Download IAM policy
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json

# Create IAM policy
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam-policy.json \
  --region "${AWS_REGION_EAST}" \
  --profile "${AWS_PROFILE}"

# Create IRSA
eksctl create iamserviceaccount \
  --cluster="${CLUSTER_NAME_EAST}" \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn="arn:aws-us-gov:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy" \
  --override-existing-serviceaccounts \
  --region "${AWS_REGION_EAST}" \
  --profile "${AWS_PROFILE}" \
  --approve

# Install via Helm
helm repo add eks https://aws.github.io/eks-charts
helm repo update

VPC_ID=$(aws eks describe-cluster \
  --name "${CLUSTER_NAME_EAST}" \
  --region "${AWS_REGION_EAST}" \
  --profile "${AWS_PROFILE}" \
  --query 'cluster.resourcesVpcConfig.vpcId' \
  --output text)

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="${CLUSTER_NAME_EAST}" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="${AWS_REGION_EAST}" \
  --set vpcId="${VPC_ID}"
```

#### 6. Create StorageClass

```bash
# Generate StorageClass manifest
envsubst < storageclass.yaml.template > storageclass.yaml

# Apply
kubectl apply -f storageclass.yaml
```

## Validation

### 1. Check Nodes

```bash
# Verify 3 node groups across 3 AZs
kubectl get nodes -L topology.kubernetes.io/zone

# Expected output: 3 nodes labeled with different AZs
```

### 2. Check StorageClass

```bash
kubectl get storageclass ${STORAGE_CLASS_NAME}
kubectl describe storageclass ${STORAGE_CLASS_NAME}

# Verify:
# - volumeBindingMode: WaitForFirstConsumer
# - kmsKeyId is set to your CMK ARN
```

### 3. Check AWS LB Controller

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Expected: 2 controller pods running
```

### 4. Test PVC Creation

```bash
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

kubectl get pvc test-pvc-phase1
# Expected: Status=Pending (waiting for pod due to WaitForFirstConsumer)

# Cleanup
kubectl delete pvc test-pvc-phase1
```

### 5. Check EKS Cluster Info

```bash
eksctl get cluster --name "${CLUSTER_NAME_EAST}" --region "${AWS_REGION_EAST}" --profile "${AWS_PROFILE}"
eksctl get nodegroup --cluster "${CLUSTER_NAME_EAST}" --region "${AWS_REGION_EAST}" --profile "${AWS_PROFILE}"
```

## Success Criteria

Phase 1 is complete when:

- ✅ EKS cluster running with Kubernetes ${EKS_VERSION}
- ✅ 3 CockroachDB node groups (one per AZ) operational
- ✅ 1 Application node group (multi-AZ) operational
- ✅ StorageClass created with CMK encryption and WaitForFirstConsumer
- ✅ AWS LB Controller pods running
- ✅ Test PVC can be created (stays Pending until pod scheduled)
- ✅ KMS key created and configured
- ✅ S3 buckets created with Object Lock

## Troubleshooting

### Issue: eksctl command hangs

**Solution**: Check AWS credentials and region
```bash
aws sts get-caller-identity --profile "${AWS_PROFILE}"
```

### Issue: IAM permissions errors

**Solution**: Verify permissions boundary is set correctly in config.env, or remove if not needed.

### Issue: Node groups fail to create

**Solution**: Check instance types are available in your region/AZs
```bash
aws ec2 describe-instance-types \
  --instance-types "${CRDB_NODE_INSTANCE_TYPE}" \
  --region "${AWS_REGION_EAST}" \
  --profile "${AWS_PROFILE}"
```

### Issue: StorageClass not using KMS key

**Solution**: Verify KMS_KEY_ARN_EAST is set and exported before running envsubst
```bash
echo $KMS_KEY_ARN_EAST
# Should show your KMS key ARN
```

## Next Steps

Proceed to Phase 2: Certificates (HashiCorp Vault PKI + cert-manager)

```bash
cd ../phase2-certificates
```

## Files Generated

After successful deployment:
- `cluster-east.generated.yaml` - EKS cluster config with your values
- `storageclass.yaml` - StorageClass manifest with your KMS key
- `iam-policy.json` - LB controller IAM policy (temporary)

These files contain your specific configuration and should not be committed to Git.
Add to `.gitignore`:
```
*.generated.yaml
storageclass.yaml
iam-policy.json
```
