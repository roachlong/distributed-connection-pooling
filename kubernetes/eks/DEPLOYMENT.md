# AWS EKS Reference Architecture (GovCloud)

This reference architecture deploys a **production-ready, FedRAMP-compliant** CockroachDB cluster with distributed connection pooling on AWS GovCloud using the CockroachDB Kubernetes Operator with **Physical Cluster Replication (PCR)** for disaster recovery.

## Overview

**Architecture Components:**
- **Dual EKS Clusters**: Active (us-gov-east-1) and Passive (us-gov-west-1) for PCR
- **CockroachDB Operator**: Kubernetes operator for automated CRDB lifecycle management
- **CockroachDB StatefulSet**: Database tier with persistent volumes and 3-AZ pod anti-affinity
- **Virtual Cluster Architecture**: PCR uses `main` virtual cluster on top of system tenant
- **PgBouncer Deployment**: Connection pooling layer deployed as Kubernetes pods
- **AWS Network Load Balancer**: External access to PgBouncer and DB Console
- **HashiCorp Vault PKI**: Certificate management with cert-manager integration
- **ArgoCD**: GitOps-based deployment and lifecycle management
- **IAM Roles for Service Accounts (IRSA)**: S3 access for backups without hardcoded credentials

**Security & Compliance Features:**
- **Physical Cluster Replication**: Active-passive DR across GovCloud regions
- **EBS Encryption**: Customer-managed KMS keys (CMK) for OCC compliance
- **CockroachDB Encryption-at-Rest**: Database-level encryption (Enterprise license required)
- **FIPS 140-3**: FIPS-validated CockroachDB binary for GovCloud
- **mTLS Everywhere**: Vault PKI-issued certificates for all cluster communication
- **Network Policies**: Deny-all default with explicit allow rules (no pod-to-internet egress)
- **Audit Log Pipeline**: Fluent Bit → S3 with Object Lock (WORM) for 7-year retention
- **IRSA for S3**: IAM roles attached to service accounts for secure S3 access
- **Private Subnets**: Worker nodes in private subnets with NAT gateway for outbound

**Key Differences from EC2 Architecture:**
- Kubernetes-native resource management vs. EC2 instances
- CockroachDB Operator automates cluster lifecycle (scaling, upgrades, failover)
- Physical Cluster Replication (PCR) replaces multi-region geo-partitioning
- Virtual cluster architecture required for PCR
- Kubernetes Services replace HAProxy + Keepalived for load balancing
- StatefulSets with PersistentVolumeClaims instead of EC2 EBS volumes
- ArgoCD/GitOps-based deployment instead of Terraform + cloud-init
- Vault PKI + cert-manager for certificate automation
- No bastion hosts needed - `kubectl exec` or port-forward for admin access

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Implementation Plan](#implementation-plan)
- [GovCloud Pre-Requisites](#govcloud-pre-requisites)
- [EKS Cluster Setup (3-AZ Topology)](#eks-cluster-setup-3-az-topology)
- [GitOps / ArgoCD Integration](#gitops--argocd-integration)
- [HashiCorp Vault PKI Setup](#hashicorp-vault-pki-setup)
- [CockroachDB Operator Installation](#cockroachdb-operator-installation)
- [CockroachDB Cluster Deployment](#cockroachdb-cluster-deployment)
- [Enterprise License Injection](#enterprise-license-injection)
- [Active-Passive PCR Topology](#active-passive-pcr-topology)
- [PgBouncer Deployment](#pgbouncer-deployment)
- [Load Balancing and External Access](#load-balancing-and-external-access)
- [Network Policies](#network-policies)
- [Encryption-at-Rest](#encryption-at-rest)
- [Audit Log Pipeline](#audit-log-pipeline)
- [Scheduling Automated Backups](#scheduling-automated-backups)
- [Monitoring with Prometheus and Grafana](#monitoring-with-prometheus-and-grafana)
- [Common Operations](#common-operations)
- [Failover and Failback Procedures](#failover-and-failback-procedures)
- [Security Notes](#security-notes)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Tools and CLI Setup

**Required tools:**
- `kubectl` (v1.28+) - Kubernetes command-line tool
- `helm` (v3.12+) - Kubernetes package manager
- `eksctl` or Terraform - for EKS cluster provisioning
- `aws` CLI (v2) - for AWS resource management
- `argocd` CLI - for ArgoCD application management
- `jq` - JSON parsing
- `cockroach` CLI - for database operations

**Installation:**

```bash
# macOS
brew install kubectl helm eksctl awscli argocd jq cockroachdb/tap/cockroach

# Linux
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# eksctl
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

# argocd
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd
sudo mv argocd /usr/local/bin/

# jq
sudo apt-get install jq  # or yum install jq

# cockroach CLI
curl https://binaries.cockroachdb.com/cockroach-v25.4.3.linux-amd64.tgz | tar -xz
sudo cp -i cockroach-v25.4.3.linux-amd64/cockroach /usr/local/bin/
```

### AWS GovCloud Account Setup

<details>
<summary>AWS CLI and SSO Configuration (click to expand)</summary>

**Configure AWS SSO for GovCloud and verify access:**

```bash
# Login via SSO
aws sso login --profile govcloud-revenue

# Set default region
export AWS_REGION=us-gov-east-1

# Verify access
aws eks list-clusters --region us-gov-east-1
aws eks list-clusters --region us-gov-west-1
```

</details>

### IAM Permissions

Ensure your AWS user/role has permissions for:
- EKS cluster creation and management (us-gov-east-1 and us-gov-west-1)
- EC2 (for worker nodes, VPC, subnets, security groups, Transit Gateway)
- IAM (for IRSA - IAM Roles for Service Accounts)
- S3 (for backups and audit logs bucket creation with Object Lock)
- KMS (for customer-managed keys)
- ECR (for private container registry)
- Route53 (optional, for DNS)

### HashiCorp Vault

This deployment requires a running HashiCorp Vault instance for:
- PKI certificate management
- Enterprise license storage
- Secret injection via External Secrets Operator

**Vault requirements:**
- Vault server accessible from EKS clusters (both regions)
- OIDC auth method configured for Kubernetes
- PKI secrets engine mounted at `pki/`
- KV v2 secrets engine for license and credentials

### Checklist

Before deploying, ensure:

- ✅ AWS GovCloud credentials configured and tested (both regions)
- ✅ kubectl, helm, eksctl, argocd, aws CLI, cockroach CLI installed
- ✅ IAM permissions for EKS, EC2, IAM, S3, KMS, ECR, Transit Gateway
- ✅ HashiCorp Vault deployed and accessible
- ✅ ArgoCD repository for GitOps manifests created
- ✅ Customer-managed KMS key created in both regions
- ✅ S3 buckets for backups and audit logs with Object Lock enabled

---

## GovCloud Pre-Requisites

AWS GovCloud has specific constraints that require pre-deployment configuration.

### 1. Container Image Mirroring to ECR

GovCloud does not have access to public container registries (`docker.io`, `public.ecr.aws`, `ghcr.io`). All images must be mirrored to a private ECR repository in GovCloud.

**Required images:**
- `cockroachdb/cockroach:v25.4.3-fips` (FIPS 140-3 validated binary)
- `cockroachdb/cockroach-operator:v2.15.0`
- `pgbouncer/pgbouncer:1.22.1`
- `fluent/fluent-bit:3.0.2`
- `hashicorp/vault-k8s:1.4.0` (for Vault Agent Injector)
- `external-secrets/external-secrets:v0.9.13`
- `jetstack/cert-manager-controller:v1.14.3`
- `jetstack/cert-manager-webhook:v1.14.3`
- `jetstack/cert-manager-cainjector:v1.14.3`

**Mirror images to GovCloud ECR:**

```bash
# Set variables
export AWS_ACCOUNT_ID=123456789012
export AWS_REGION=us-gov-east-1
export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Login to commercial AWS ECR public and GovCloud ECR
aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws
aws ecr get-login-password --region ${AWS_REGION} --profile govcloud-revenue | docker login --username AWS --password-stdin ${ECR_REGISTRY}

# Create ECR repositories
for repo in cockroachdb cockroach-operator pgbouncer fluent-bit vault-k8s external-secrets cert-manager-controller cert-manager-webhook cert-manager-cainjector; do
  aws ecr create-repository --repository-name ${repo} --region ${AWS_REGION} --profile govcloud-revenue || true
done

# Mirror CockroachDB FIPS binary
docker pull cockroachdb/cockroach:v25.4.3-fips
docker tag cockroachdb/cockroach:v25.4.3-fips ${ECR_REGISTRY}/cockroachdb:v25.4.3-fips
docker push ${ECR_REGISTRY}/cockroachdb:v25.4.3-fips

# Mirror CockroachDB Operator
docker pull cockroachdb/cockroach-operator:v2.15.0
docker tag cockroachdb/cockroach-operator:v2.15.0 ${ECR_REGISTRY}/cockroach-operator:v2.15.0
docker push ${ECR_REGISTRY}/cockroach-operator:v2.15.0

# Mirror PgBouncer
docker pull pgbouncer/pgbouncer:1.22.1
docker tag pgbouncer/pgbouncer:1.22.1 ${ECR_REGISTRY}/pgbouncer:1.22.1
docker push ${ECR_REGISTRY}/pgbouncer:1.22.1

# Mirror Fluent Bit
docker pull fluent/fluent-bit:3.0.2
docker tag fluent/fluent-bit:3.0.2 ${ECR_REGISTRY}/fluent-bit:3.0.2
docker push ${ECR_REGISTRY}/fluent-bit:3.0.2

# Mirror Vault, External Secrets, cert-manager (similar pattern)
# ... (repeat for each image)
```

**Repeat for us-gov-west-1** (passive cluster region).

### 2. Customer-Managed KMS Key (CMK)

Create a customer-managed KMS key in each region for EBS encryption to satisfy OCC CMK requirements.

```bash
# Create CMK in us-gov-east-1
aws kms create-key \
  --description "CockroachDB EBS encryption key - us-gov-east-1" \
  --region us-gov-east-1 \
  --profile govcloud-revenue

# Create alias
aws kms create-alias \
  --alias-name alias/crdb-ebs-east \
  --target-key-id <key-id-from-above> \
  --region us-gov-east-1 \
  --profile govcloud-revenue

# Get KMS key ARN (save for StorageClass configuration)
export KMS_KEY_ARN_EAST=$(aws kms describe-key --key-id alias/crdb-ebs-east --region us-gov-east-1 --profile govcloud-revenue --query 'KeyMetadata.Arn' --output text)

# Repeat for us-gov-west-1
aws kms create-key \
  --description "CockroachDB EBS encryption key - us-gov-west-1" \
  --region us-gov-west-1 \
  --profile govcloud-revenue

aws kms create-alias \
  --alias-name alias/crdb-ebs-west \
  --target-key-id <key-id-from-above> \
  --region us-gov-west-1 \
  --profile govcloud-revenue

export KMS_KEY_ARN_WEST=$(aws kms describe-key --key-id alias/crdb-ebs-west --region us-gov-west-1 --profile govcloud-revenue --query 'KeyMetadata.Arn' --output text)
```

### 3. S3 Buckets with Object Lock (WORM)

Create separate S3 buckets for backups and audit logs with Object Lock for compliance.

```bash
# Backup bucket (365-day retention)
aws s3api create-bucket \
  --bucket crdb-backups-govcloud-east \
  --region us-gov-east-1 \
  --create-bucket-configuration LocationConstraint=us-gov-east-1 \
  --object-lock-enabled-for-bucket \
  --profile govcloud-revenue

aws s3api put-object-lock-configuration \
  --bucket crdb-backups-govcloud-east \
  --object-lock-configuration 'Rule={DefaultRetention={Mode=COMPLIANCE,Days=365}}' \
  --region us-gov-east-1 \
  --profile govcloud-revenue

# Audit log bucket (7-year retention with Object Lock)
aws s3api create-bucket \
  --bucket crdb-audit-logs-govcloud-east \
  --region us-gov-east-1 \
  --create-bucket-configuration LocationConstraint=us-gov-east-1 \
  --object-lock-enabled-for-bucket \
  --profile govcloud-revenue

aws s3api put-object-lock-configuration \
  --bucket crdb-audit-logs-govcloud-east \
  --object-lock-configuration 'Rule={DefaultRetention={Mode=COMPLIANCE,Days=2555}}' \
  --region us-gov-east-1 \
  --profile govcloud-revenue

# Enable server-side encryption with KMS
aws s3api put-bucket-encryption \
  --bucket crdb-backups-govcloud-east \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms",
        "KMSMasterKeyID": "'${KMS_KEY_ARN_EAST}'"
      }
    }]
  }' \
  --region us-gov-east-1 \
  --profile govcloud-revenue

aws s3api put-bucket-encryption \
  --bucket crdb-audit-logs-govcloud-east \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms",
        "KMSMasterKeyID": "'${KMS_KEY_ARN_EAST}'"
      }
    }]
  }' \
  --region us-gov-east-1 \
  --profile govcloud-revenue

# Repeat for us-gov-west-1
```

### 4. FIPS 140-3 Binary Verification

Verify the CockroachDB FIPS binary is available for your target version:

```bash
# Check FIPS binary availability
docker pull ${ECR_REGISTRY}/cockroachdb:v25.4.3-fips
docker run --rm ${ECR_REGISTRY}/cockroachdb:v25.4.3-fips version

# Expected output should indicate FIPS mode
# Build Tag:    v25.4.3-fips
# FIPS Mode:    enabled
```

---

## EKS Cluster Setup (3-AZ Topology)

Deploy EKS clusters in both us-gov-east-1 (active) and us-gov-west-1 (passive) with explicit 3-AZ node placement for local quorum.

### Architecture Requirements

**3-AZ Topology for Local Quorum:**
- Managed node groups spanning us-gov-east-1a, us-gov-east-1b, us-gov-east-1c
- Pod anti-affinity rules forcing one CockroachDB pod per AZ
- topologySpreadConstraints for even distribution
- `volumeBindingMode: WaitForFirstConsumer` in StorageClass for AZ-aware EBS provisioning

### Option 1: Using eksctl

Create `cluster-east.yaml`:

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: crdb-dcp-east
  region: us-gov-east-1
  version: "1.28"

iam:
  withOIDC: true

vpc:
  cidr: 10.10.0.0/16
  nat:
    gateway: Single  # NAT gateway for private subnet outbound

availabilityZones:
  - us-gov-east-1a
  - us-gov-east-1b
  - us-gov-east-1c

managedNodeGroups:
  - name: crdb-nodes-1a
    instanceType: m5.2xlarge
    desiredCapacity: 1
    minSize: 1
    maxSize: 3
    availabilityZones:
      - us-gov-east-1a
    privateNetworking: true
    labels:
      role: cockroachdb
      topology.kubernetes.io/zone: us-gov-east-1a
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/crdb-dcp-east: "owned"

  - name: crdb-nodes-1b
    instanceType: m5.2xlarge
    desiredCapacity: 1
    minSize: 1
    maxSize: 3
    availabilityZones:
      - us-gov-east-1b
    privateNetworking: true
    labels:
      role: cockroachdb
      topology.kubernetes.io/zone: us-gov-east-1b
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/crdb-dcp-east: "owned"

  - name: crdb-nodes-1c
    instanceType: m5.2xlarge
    desiredCapacity: 1
    minSize: 1
    maxSize: 3
    availabilityZones:
      - us-gov-east-1c
    privateNetworking: true
    labels:
      role: cockroachdb
      topology.kubernetes.io/zone: us-gov-east-1c
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/crdb-dcp-east: "owned"

  - name: app-nodes
    instanceType: c5.xlarge
    desiredCapacity: 3
    minSize: 3
    maxSize: 9
    availabilityZones:
      - us-gov-east-1a
      - us-gov-east-1b
      - us-gov-east-1c
    privateNetworking: true
    labels:
      role: application

addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: aws-ebs-csi-driver
    version: latest
    serviceAccountRoleARN: arn:aws-us-gov:iam::123456789012:role/AmazonEKS_EBS_CSI_DriverRole
```

**Deploy the cluster:**

```bash
eksctl create cluster -f cluster-east.yaml --profile govcloud-revenue
```

**Repeat for West cluster** (`cluster-west.yaml` with us-gov-west-1 regions).

### Option 2: Using Terraform

Create `eks-east.tf`:

```hcl
# TODO: Terraform EKS module with 3-AZ node groups
# Similar structure to eksctl config above
```

### Install AWS Load Balancer Controller

Required for exposing services via Network Load Balancer:

```bash
# Create IAM policy for ALB controller
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam-policy.json \
  --region us-gov-east-1 \
  --profile govcloud-revenue

# Create IRSA for ALB controller
eksctl create iamserviceaccount \
  --cluster=crdb-dcp-east \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws-us-gov:iam::123456789012:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --region us-gov-east-1 \
  --profile govcloud-revenue \
  --approve

# Install ALB controller via Helm
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=crdb-dcp-east \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=us-gov-east-1 \
  --set vpcId=<vpc-id>
```

### Create StorageClass with WaitForFirstConsumer

Create `storageclass-crdb.yaml`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: crdb-gp3-encrypted
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "16000"
  throughput: "1000"
  encrypted: "true"
  kmsKeyId: "arn:aws-us-gov:kms:us-gov-east-1:123456789012:key/<key-id>"  # Customer-managed key
volumeBindingMode: WaitForFirstConsumer  # Critical for AZ-aware provisioning
allowVolumeExpansion: true
reclaimPolicy: Retain
```

Apply to both clusters:

```bash
kubectl apply -f storageclass-crdb.yaml --context crdb-dcp-east
kubectl apply -f storageclass-crdb.yaml --context crdb-dcp-west
```

### Configure Cross-Cluster Networking (Transit Gateway)

For PCR replication traffic between East and West clusters:

```bash
# TODO: Transit Gateway setup between us-gov-east-1 and us-gov-west-1 VPCs
# - Create Transit Gateway in each region
# - Create TGW peering connection
# - Update route tables to allow CRDB pod-to-pod communication on port 26257
# - Update security groups to allow cross-region traffic
```

---

## GitOps / ArgoCD Integration

All Kubernetes resources are deployed via ArgoCD for GitOps-based lifecycle management.

### ArgoCD Installation

Install ArgoCD in both clusters:

```bash
kubectl create namespace argocd --context crdb-dcp-east
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --context crdb-dcp-east

# Repeat for West
kubectl create namespace argocd --context crdb-dcp-west
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --context crdb-dcp-west

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" --context crdb-dcp-east | base64 -d

# Expose ArgoCD UI via port-forward
kubectl port-forward svc/argocd-server -n argocd 8080:443 --context crdb-dcp-east
```

### Git Repository Structure

Create a Git repository with the following structure:

```
crdb-dcp-govcloud/
├── clusters/
│   ├── east/
│   │   ├── argocd-apps/          # ArgoCD Application manifests
│   │   │   ├── cert-manager.yaml
│   │   │   ├── external-secrets.yaml
│   │   │   ├── cockroachdb-operator.yaml
│   │   │   ├── cockroachdb-cluster.yaml
│   │   │   ├── pgbouncer.yaml
│   │   │   ├── fluent-bit.yaml
│   │   │   └── network-policies.yaml
│   │   └── kustomization.yaml
│   └── west/
│       ├── argocd-apps/          # Same structure as east
│       └── kustomization.yaml
├── base/
│   ├── cert-manager/
│   │   ├── kustomization.yaml
│   │   └── values.yaml
│   ├── external-secrets/
│   ├── cockroachdb-operator/
│   ├── cockroachdb-cluster/
│   │   ├── crdb-east.yaml        # CockroachDB CR for East (active)
│   │   ├── crdb-west.yaml        # CockroachDB CR for West (passive)
│   │   ├── service.yaml
│   │   └── kustomization.yaml
│   ├── pgbouncer/
│   │   ├── deployment.yaml
│   │   ├── configmap.yaml
│   │   ├── service.yaml
│   │   └── kustomization.yaml
│   ├── fluent-bit/
│   └── network-policies/
└── overlays/
    ├── east/
    └── west/
```

### ArgoCD Application Pattern

All resources are deployed via ArgoCD Applications, not `kubectl apply`. Example for CockroachDB Operator:

**clusters/east/argocd-apps/cockroachdb-operator.yaml:**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cockroachdb-operator
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/yourorg/crdb-dcp-govcloud.git
    targetRevision: main
    path: base/cockroachdb-operator
  destination:
    server: https://kubernetes.default.svc
    namespace: cockroach-operator-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Apply the ArgoCD Application:

```bash
kubectl apply -f clusters/east/argocd-apps/cockroachdb-operator.yaml --context crdb-dcp-east
```

**All subsequent deployments follow this pattern** - changes go through Git PR → ArgoCD sync, not imperative kubectl commands.

---

## HashiCorp Vault PKI Setup

Configure Vault PKI for mTLS certificate management with cert-manager integration.

### 1. Enable PKI Secrets Engine

```bash
# Enable PKI at pki/ mount
vault secrets enable -path=pki pki

# Tune TTL to 10 years for CA
vault secrets tune -max-lease-ttl=87600h pki

# Generate root CA
vault write -field=certificate pki/root/generate/internal \
  common_name="CockroachDB Root CA" \
  issuer_name="root-ca" \
  ttl=87600h > ca.crt

# Configure CA and CRL URLs
vault write pki/config/urls \
  issuing_certificates="https://vault.example.com:8200/v1/pki/ca" \
  crl_distribution_points="https://vault.example.com:8200/v1/pki/crl"
```

### 2. Create PKI Role for CockroachDB

```bash
# Create role for node certificates
vault write pki/roles/cockroachdb-node \
  allowed_domains="cockroachdb,cockroachdb.cockroachdb,cockroachdb.cockroachdb.svc,cockroachdb.cockroachdb.svc.cluster.local,localhost,node" \
  allow_subdomains=true \
  allow_bare_domains=true \
  allow_localhost=true \
  allow_ip_sans=true \
  client_flag=true \
  server_flag=true \
  max_ttl=8760h \
  ttl=2160h

# Create role for client certificates
vault write pki/roles/cockroachdb-client \
  allowed_domains="root,admin,pgbouncer" \
  allow_bare_domains=true \
  client_flag=true \
  max_ttl=8760h \
  ttl=2160h
```

### 3. Configure Kubernetes Auth

```bash
# Enable Kubernetes auth
vault auth enable -path=kubernetes-east kubernetes

# Configure Kubernetes auth with EKS cluster
vault write auth/kubernetes-east/config \
  kubernetes_host="https://<eks-api-endpoint>" \
  kubernetes_ca_cert=@/path/to/ca.crt \
  token_reviewer_jwt="<service-account-jwt>"

# Create policy for cert-manager
vault policy write cert-manager-policy - <<EOF
path "pki/sign/cockroachdb-node" {
  capabilities = ["create", "update"]
}
path "pki/sign/cockroachdb-client" {
  capabilities = ["create", "update"]
}
EOF

# Create Kubernetes role for cert-manager
vault write auth/kubernetes-east/role/cert-manager \
  bound_service_account_names=cert-manager \
  bound_service_account_namespaces=cert-manager \
  policies=cert-manager-policy \
  ttl=1h
```

### 4. Deploy cert-manager

Create ArgoCD Application for cert-manager:

**base/cert-manager/values.yaml:**

```yaml
installCRDs: true
image:
  repository: 123456789012.dkr.ecr.us-gov-east-1.amazonaws.com/cert-manager-controller
  tag: v1.14.3
webhook:
  image:
    repository: 123456789012.dkr.ecr.us-gov-east-1.amazonaws.com/cert-manager-webhook
    tag: v1.14.3
cainjector:
  image:
    repository: 123456789012.dkr.ecr.us-gov-east-1.amazonaws.com/cert-manager-cainjector
    tag: v1.14.3
```

### 5. Create Vault ClusterIssuer

**base/cert-manager/vault-issuer.yaml:**

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-issuer
spec:
  vault:
    server: https://vault.example.com:8200
    path: pki/sign/cockroachdb-node
    auth:
      kubernetes:
        role: cert-manager
        mountPath: /v1/auth/kubernetes-east
        secretRef:
          name: cert-manager-vault-token
          key: token
```

### 6. Configure cert-manager to Issue Certificates

**Example Certificate resource (managed by CockroachDB Operator or created manually):**

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cockroachdb-node
  namespace: cockroachdb
spec:
  secretName: cockroachdb-node-secret
  issuerRef:
    name: vault-issuer
    kind: ClusterIssuer
  commonName: node
  dnsNames:
    - localhost
    - cockroachdb-public
    - cockroachdb-public.cockroachdb
    - cockroachdb-public.cockroachdb.svc.cluster.local
    - "*.cockroachdb"
    - "*.cockroachdb.cockroachdb"
    - "*.cockroachdb.cockroachdb.svc.cluster.local"
  ipAddresses:
    - 127.0.0.1
  duration: 2160h  # 90 days
  renewBefore: 720h  # 30 days
  usages:
    - server auth
    - client auth
```

cert-manager will automatically renew certificates before expiry.

---

## CockroachDB Operator Installation

Install the CockroachDB Operator via ArgoCD.

### Create Operator ArgoCD Application

**base/cockroachdb-operator/kustomization.yaml:**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - https://raw.githubusercontent.com/cockroachdb/cockroach-operator/v2.15.0/install/crds.yaml
  - https://raw.githubusercontent.com/cockroachdb/cockroach-operator/v2.15.0/install/operator.yaml

images:
  - name: cockroachdb/cockroach-operator
    newName: 123456789012.dkr.ecr.us-gov-east-1.amazonaws.com/cockroach-operator
    newTag: v2.15.0

namespace: cockroach-operator-system
```

**clusters/east/argocd-apps/cockroachdb-operator.yaml:**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cockroachdb-operator
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/yourorg/crdb-dcp-govcloud.git
    targetRevision: main
    path: base/cockroachdb-operator
  destination:
    server: https://kubernetes.default.svc
    namespace: cockroach-operator-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Apply via ArgoCD:

```bash
kubectl apply -f clusters/east/argocd-apps/cockroachdb-operator.yaml --context crdb-dcp-east
kubectl apply -f clusters/west/argocd-apps/cockroachdb-operator.yaml --context crdb-dcp-west
```

### Verify Operator Installation

```bash
kubectl get pods -n cockroach-operator-system --context crdb-dcp-east
# Expected: cockroach-operator pod running
```

---

## CockroachDB Cluster Deployment

Deploy CockroachDB clusters in both regions using the Operator.

### Create Namespace

```bash
kubectl create namespace cockroachdb --context crdb-dcp-east
kubectl create namespace cockroachdb --context crdb-dcp-west
```

### Configure CockroachDB Custom Resource (East - Active)

**base/cockroachdb-cluster/crdb-east.yaml:**

```yaml
apiVersion: crdb.cockroachlabs.com/v1alpha1
kind: CrdbCluster
metadata:
  name: cockroachdb-east
  namespace: cockroachdb
spec:
  # FIPS-validated binary from GovCloud ECR
  image:
    name: 123456789012.dkr.ecr.us-gov-east-1.amazonaws.com/cockroachdb:v25.4.3-fips
  
  # 3 nodes for quorum (one per AZ)
  nodes: 3
  
  # Resources per pod
  resources:
    requests:
      cpu: "4"
      memory: "16Gi"
    limits:
      cpu: "8"
      memory: "32Gi"
  
  # Persistent storage with CMK encryption
  dataStore:
    pvc:
      spec:
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 100Gi
        storageClassName: crdb-gp3-encrypted  # WaitForFirstConsumer with CMK
  
  # 3-AZ topology with pod anti-affinity
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          app: cockroachdb-east
  
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchExpressions:
              - key: app
                operator: In
                values:
                  - cockroachdb-east
          topologyKey: topology.kubernetes.io/zone
  
  # Node selector for CRDB-dedicated nodes
  nodeSelector:
    role: cockroachdb
  
  # TLS configuration (Vault PKI + cert-manager)
  tlsEnabled: true
  nodeTLSSecret: cockroachdb-node-secret  # Created by cert-manager
  clientTLSSecret: cockroachdb-client-secret
  
  # Cluster settings for PCR
  additionalArgs:
    - --locality=region=us-gov-east-1,zone=$(POD_NAMESPACE)
    - --cluster-name=crdb-east
  
  # Cluster init settings
  cockroachDBVersion: v25.4.3
  
  # Enable rangefeed for PCR (set via SQL after cluster init)
  # cluster.organization and enterprise.license injected via secret
```

### Configure CockroachDB Custom Resource (West - Passive)

**base/cockroachdb-cluster/crdb-west.yaml:**

Similar to East but with:
- `name: cockroachdb-west`
- `image` pointing to us-gov-west-1 ECR
- `--locality=region=us-gov-west-1`
- `--cluster-name=crdb-west`
- StorageClass pointing to west region CMK

### Pod Anti-Affinity and Topology Spread

The `topologySpreadConstraints` and `podAntiAffinity` rules ensure:
- One CockroachDB pod per AZ (us-gov-east-1a, 1b, 1c)
- Even distribution across zones
- No two pods scheduled on the same zone (hard requirement)

Combined with `volumeBindingMode: WaitForFirstConsumer`, this ensures:
- EBS volumes are created in the same AZ as the pod
- Pods can always attach to their volumes after rescheduling

### Deploy via ArgoCD

**clusters/east/argocd-apps/cockroachdb-cluster.yaml:**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cockroachdb-cluster-east
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/yourorg/crdb-dcp-govcloud.git
    targetRevision: main
    path: base/cockroachdb-cluster
    kustomize:
      namePrefix: east-
  destination:
    server: https://kubernetes.default.svc
    namespace: cockroachdb
  syncPolicy:
    automated:
      prune: false  # Don't auto-delete database!
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Apply:

```bash
kubectl apply -f clusters/east/argocd-apps/cockroachdb-cluster.yaml --context crdb-dcp-east
kubectl apply -f clusters/west/argocd-apps/cockroachdb-cluster.yaml --context crdb-dcp-west
```

### Verify Cluster Deployment

```bash
# Check pods
kubectl get pods -n cockroachdb --context crdb-dcp-east
# Expected: cockroachdb-east-0, cockroachdb-east-1, cockroachdb-east-2 (one per AZ)

# Check pod distribution across AZs
kubectl get pods -n cockroachdb -o wide --context crdb-dcp-east
# Verify NODE column shows nodes from different AZs

# Check PVCs
kubectl get pvc -n cockroachdb --context crdb-dcp-east
# Expected: 3 PVCs, all Bound

# Check cluster status via SQL
kubectl exec -it cockroachdb-east-0 -n cockroachdb --context crdb-dcp-east -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost -e "SHOW CLUSTER SETTING cluster.organization;"
```

---

## Enterprise License Injection

The Enterprise license is required for PCR, encryption-at-rest, and audit logging. Store it in Vault and inject via Kubernetes Secret.

### 1. Store License in Vault

```bash
vault kv put secret/cockroachdb/license \
  organization="YourCompany" \
  license="crl-0-xxxxxxxxxxxxxxxxxxxxx..."
```

### 2. Deploy External Secrets Operator

**base/external-secrets/kustomization.yaml:**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - https://raw.githubusercontent.com/external-secrets/external-secrets/v0.9.13/deploy/crds/bundle.yaml
  - https://raw.githubusercontent.com/external-secrets/external-secrets/v0.9.13/deploy/kubernetes/external-secrets.yaml

images:
  - name: ghcr.io/external-secrets/external-secrets
    newName: 123456789012.dkr.ecr.us-gov-east-1.amazonaws.com/external-secrets
    newTag: v0.9.13
```

### 3. Configure SecretStore

**base/external-secrets/vault-secret-store.yaml:**

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "https://vault.example.com:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes-east"
          role: "external-secrets"
          serviceAccountRef:
            name: "external-secrets"
```

### 4. Create ExternalSecret for License

**base/cockroachdb-cluster/license-external-secret.yaml:**

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: cockroachdb-license
  namespace: cockroachdb
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: cockroachdb-license
    creationPolicy: Owner
  data:
    - secretKey: organization
      remoteRef:
        key: secret/cockroachdb/license
        property: organization
    - secretKey: license
      remoteRef:
        key: secret/cockroachdb/license
        property: license
```

### 5. Apply License via SQL

After cluster init, the operator or init job can apply the license:

```bash
kubectl exec -it cockroachdb-east-0 -n cockroachdb --context crdb-dcp-east -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost <<EOF
SET CLUSTER SETTING cluster.organization = '$(kubectl get secret cockroachdb-license -n cockroachdb -o jsonpath='{.data.organization}' | base64 -d)';
SET CLUSTER SETTING enterprise.license = '$(kubectl get secret cockroachdb-license -n cockroachdb -o jsonpath='{.data.license}' | base64 -d)';
EOF
```

**Or inject via init container in CockroachDB CR** (preferred for GitOps):

```yaml
spec:
  additionalArgs:
    - --env=COCKROACH_ORGANIZATION=$(COCKROACH_ORGANIZATION)
    - --env=COCKROACH_LICENSE=$(COCKROACH_LICENSE)
  env:
    - name: COCKROACH_ORGANIZATION
      valueFrom:
        secretKeyRef:
          name: cockroachdb-license
          key: organization
    - name: COCKROACH_LICENSE
      valueFrom:
        secretKeyRef:
          name: cockroachdb-license
          key: license
```

---

## Active-Passive PCR Topology

Physical Cluster Replication (PCR) creates an active cluster in us-gov-east-1 and a passive replica in us-gov-west-1 for disaster recovery.

### Architecture Overview

**Active Cluster (East):**
- Serves application traffic
- main virtual cluster handles reads/writes
- Rangefeed streams changes to West cluster

**Passive Cluster (West):**
- Receives replication stream from East
- main virtual cluster is read-only (replicating)
- Cannot serve writes until promoted (failover)

**Virtual Cluster Architecture:**
- System tenant manages the physical infrastructure
- `main` virtual cluster is where applications connect
- PCR replicates the `main` virtual cluster, not the system tenant

### Prerequisites for PCR

1. **Cross-cluster network connectivity**: Transit Gateway or VPC peering between East and West VPCs
2. **Rangefeed enabled**: `SET CLUSTER SETTING kv.rangefeed.enabled = true` on both clusters
3. **Enterprise license**: Applied to both clusters
4. **Connection string**: West cluster needs connection string to East cluster

### 1. Enable Rangefeed on Both Clusters

```bash
# East cluster
kubectl exec -it cockroachdb-east-0 -n cockroachdb --context crdb-dcp-east -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost -e \
  "SET CLUSTER SETTING kv.rangefeed.enabled = true;"

# West cluster
kubectl exec -it cockroachdb-west-0 -n cockroachdb --context crdb-dcp-west -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost -e \
  "SET CLUSTER SETTING kv.rangefeed.enabled = true;"
```

### 2. Get Connection String for East Cluster

The West cluster needs a connection string to the East cluster's system interface (port 26257):

```bash
# Get East cluster internal service DNS
EAST_CLUSTER_CONN="postgresql://cockroachdb-east-public.cockroachdb.svc.cluster.local:26257?sslmode=verify-full&sslrootcert=/cockroach/cockroach-certs/ca.crt&sslcert=/cockroach/cockroach-certs/client.root.crt&sslkey=/cockroach/cockroach-certs/client.root.key"
```

**Note**: For cross-region connectivity, use the Transit Gateway or VPC peering endpoint, or expose East cluster via NLB with internal DNS.

### 3. Initialize Virtual Cluster Replication (West)

On the **West (passive) cluster**, create the `main` virtual cluster from East replication:

```bash
kubectl exec -it cockroachdb-west-0 -n cockroachdb --context crdb-dcp-west -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost <<EOF
CREATE VIRTUAL CLUSTER main FROM REPLICATION OF main ON 'postgresql://cockroachdb-east-public.cockroachdb.svc.cluster.local:26257?sslmode=verify-full&sslrootcert=/cockroach/cockroach-certs/ca.crt&sslcert=/cockroach/cockroach-certs/client.root.crt&sslkey=/cockroach/cockroach-certs/client.root.key';
EOF
```

This starts the replication stream from East → West.

### 4. Verify Replication Status

```bash
# On West cluster, check replication status
kubectl exec -it cockroachdb-west-0 -n cockroachdb --context crdb-dcp-west -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost -e \
  "SHOW VIRTUAL CLUSTER main WITH REPLICATION STATUS;"

# Expected output:
#   id |  name  | data_state  | service_mode |    source_tenant_name     | replication_lag
# -----+--------+-------------+--------------+---------------------------+------------------
#    3 | main   | replicating | none         | main                      | 00:00:02.5
```

**Key fields:**
- `data_state: replicating` - West is receiving data from East
- `service_mode: none` - West is not serving traffic (passive)
- `replication_lag` - How far behind West is (should be < 10 seconds)

### 5. Application Connection Strings

**East (Active) - Applications connect here:**

```
postgresql://root@pgbouncer.cockroachdb.svc.cluster.local:5432/defaultdb?sslmode=verify-full&options=-ccluster=main
```

The `options=-ccluster=main` parameter routes connections to the `main` virtual cluster.

**West (Passive) - No application connections until failover.**

### 6. Monitoring Replication Lag

Monitor replication lag continuously:

```bash
# On West cluster
kubectl exec -it cockroachdb-west-0 -n cockroachdb --context crdb-dcp-west -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost -e \
  "SELECT lag FROM [SHOW VIRTUAL CLUSTER main WITH REPLICATION STATUS] WHERE name = 'main';"
```

**Alert if replication lag > 30 seconds** - indicates network issues or East cluster overload.

---

## PgBouncer Deployment

Deploy PgBouncer for connection pooling in front of the CockroachDB `main` virtual cluster.

### Create PgBouncer ConfigMap

**base/pgbouncer/configmap.yaml:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pgbouncer-config
  namespace: cockroachdb
data:
  pgbouncer.ini: |
    [databases]
    defaultdb = host=cockroachdb-east-public.cockroachdb.svc.cluster.local port=26257 dbname=defaultdb options=-ccluster=main

    [pgbouncer]
    listen_addr = 0.0.0.0
    listen_port = 5432
    auth_type = cert
    auth_file = /etc/pgbouncer/userlist.txt
    pool_mode = transaction
    max_client_conn = 10000
    default_pool_size = 25
    reserve_pool_size = 5
    reserve_pool_timeout = 3
    server_tls_sslmode = verify-full
    server_tls_ca_file = /etc/pgbouncer/certs/ca.crt
    server_tls_cert_file = /etc/pgbouncer/certs/client.pgbouncer.crt
    server_tls_key_file = /etc/pgbouncer/certs/client.pgbouncer.key
    client_tls_sslmode = verify-full
    client_tls_ca_file = /etc/pgbouncer/certs/ca.crt
    client_tls_cert_file = /etc/pgbouncer/certs/server.crt
    client_tls_key_file = /etc/pgbouncer/certs/server.key
    logfile = /var/log/pgbouncer/pgbouncer.log
    pidfile = /var/run/pgbouncer/pgbouncer.pid
    admin_users = admin
    stats_users = stats

  userlist.txt: |
    # cert auth - no passwords needed
```

**Note**: The `options=-ccluster=main` in the connection string routes to the virtual cluster.

### Create PgBouncer Deployment

**base/pgbouncer/deployment.yaml:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgbouncer
  namespace: cockroachdb
spec:
  replicas: 3
  selector:
    matchLabels:
      app: pgbouncer
  template:
    metadata:
      labels:
        app: pgbouncer
    spec:
      containers:
        - name: pgbouncer
          image: 123456789012.dkr.ecr.us-gov-east-1.amazonaws.com/pgbouncer:1.22.1
          ports:
            - containerPort: 5432
              name: pgbouncer
          volumeMounts:
            - name: config
              mountPath: /etc/pgbouncer
            - name: certs
              mountPath: /etc/pgbouncer/certs
              readOnly: true
            - name: logs
              mountPath: /var/log/pgbouncer
          resources:
            requests:
              cpu: "1"
              memory: "2Gi"
            limits:
              cpu: "2"
              memory: "4Gi"
      volumes:
        - name: config
          configMap:
            name: pgbouncer-config
        - name: certs
          secret:
            secretName: pgbouncer-client-secret  # cert-manager issued
        - name: logs
          emptyDir: {}
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: app
                      operator: In
                      values:
                        - pgbouncer
                topologyKey: topology.kubernetes.io/zone
```

### Create PgBouncer Service

**base/pgbouncer/service.yaml:**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: pgbouncer
  namespace: cockroachdb
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-internal: "true"  # Internal NLB
spec:
  type: LoadBalancer
  ports:
    - port: 5432
      targetPort: 5432
      protocol: TCP
      name: pgbouncer
  selector:
    app: pgbouncer
```

### Deploy via ArgoCD

```bash
kubectl apply -f clusters/east/argocd-apps/pgbouncer.yaml --context crdb-dcp-east
```

### Verify PgBouncer

```bash
# Check pods
kubectl get pods -n cockroachdb -l app=pgbouncer --context crdb-dcp-east

# Get NLB endpoint
kubectl get svc pgbouncer -n cockroachdb --context crdb-dcp-east

# Test connection
kubectl run -it --rm psql --image=postgres:15 --restart=Never -- \
  psql "postgresql://root@pgbouncer.cockroachdb.svc.cluster.local:5432/defaultdb?sslmode=verify-full&sslrootcert=/certs/ca.crt&sslcert=/certs/client.root.crt&sslkey=/certs/client.root.key&options=-ccluster=main"
```

---

## Load Balancing and External Access

Expose PgBouncer and CockroachDB DB Console via AWS Network Load Balancer.

### PgBouncer NLB (Internal)

Already created in the PgBouncer Service above with `service.beta.kubernetes.io/aws-load-balancer-internal: "true"`.

Applications within the VPC connect to:

```
pgbouncer.<nlb-dns-name>:5432
```

### DB Console NLB (Internal)

**base/cockroachdb-cluster/console-service.yaml:**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: cockroachdb-console
  namespace: cockroachdb
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-internal: "true"
spec:
  type: LoadBalancer
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
      name: http
  selector:
    app: cockroachdb-east
```

### Optional: Route53 DNS

Create Route53 records pointing to NLB endpoints:

```bash
# Get NLB DNS names
PGBOUNCER_NLB=$(kubectl get svc pgbouncer -n cockroachdb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' --context crdb-dcp-east)
CONSOLE_NLB=$(kubectl get svc cockroachdb-console -n cockroachdb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' --context crdb-dcp-east)

# Create Route53 CNAME records
aws route53 change-resource-record-sets --hosted-zone-id <zone-id> --change-batch '{
  "Changes": [{
    "Action": "CREATE",
    "ResourceRecordSet": {
      "Name": "pgb.us-gov-east-1.dcp-govcloud.example.com",
      "Type": "CNAME",
      "TTL": 300,
      "ResourceRecords": [{"Value": "'${PGBOUNCER_NLB}'"}]
    }
  }]
}'

aws route53 change-resource-record-sets --hosted-zone-id <zone-id> --change-batch '{
  "Changes": [{
    "Action": "CREATE",
    "ResourceRecordSet": {
      "Name": "db.us-gov-east-1.dcp-govcloud.example.com",
      "Type": "CNAME",
      "TTL": 300,
      "ResourceRecords": [{"Value": "'${CONSOLE_NLB}'"}]
    }
  }]
}'
```

**Application connection string:**

```
postgresql://appuser@pgb.us-gov-east-1.dcp-govcloud.example.com:5432/defaultdb?sslmode=verify-full&sslrootcert=/path/to/ca.crt&sslcert=/path/to/client.crt&sslkey=/path/to/client.key&options=-ccluster=main
```

---

## Network Policies

Implement deny-all default with explicit allow rules for GovCloud compliance (no pod-to-internet egress).

### Deny-All Default Policy

**base/network-policies/deny-all.yaml:**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress-egress
  namespace: cockroachdb
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

### Allow CockroachDB Ingress

**base/network-policies/crdb-allow-ingress.yaml:**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: crdb-allow-ingress
  namespace: cockroachdb
spec:
  podSelector:
    matchLabels:
      app: cockroachdb-east
  policyTypes:
    - Ingress
  ingress:
    # Allow from PgBouncer on port 26257 (SQL)
    - from:
        - podSelector:
            matchLabels:
              app: pgbouncer
      ports:
        - protocol: TCP
          port: 26257
    
    # Allow from monitoring namespace on port 8080 (metrics)
    - from:
        - namespaceSelector:
            matchLabels:
              name: monitoring
      ports:
        - protocol: TCP
          port: 8080
    
    # Allow from other CRDB pods on port 26257 (inter-node)
    - from:
        - podSelector:
            matchLabels:
              app: cockroachdb-east
      ports:
        - protocol: TCP
          port: 26257
    
    # Allow PCR traffic from West cluster (cross-region)
    # Note: Requires Transit Gateway CIDR or VPC peering
    - from:
        - ipBlock:
            cidr: 10.20.0.0/16  # West VPC CIDR
      ports:
        - protocol: TCP
          port: 26257
```

### Allow CockroachDB Egress

**base/network-policies/crdb-allow-egress.yaml:**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: crdb-allow-egress
  namespace: cockroachdb
spec:
  podSelector:
    matchLabels:
      app: cockroachdb-east
  policyTypes:
    - Egress
  egress:
    # Allow to other CRDB pods (inter-node)
    - to:
        - podSelector:
            matchLabels:
              app: cockroachdb-east
      ports:
        - protocol: TCP
          port: 26257
    
    # Allow to West cluster for PCR replication
    - to:
        - ipBlock:
            cidr: 10.20.0.0/16  # West VPC CIDR
      ports:
        - protocol: TCP
          port: 26257
    
    # Allow DNS (kube-dns/CoreDNS)
    - to:
        - namespaceSelector:
            matchLabels:
              name: kube-system
      ports:
        - protocol: UDP
          port: 53
    
    # Allow S3 for backups (GovCloud S3 endpoint)
    - to:
        - ipBlock:
            cidr: 52.61.0.0/16  # S3 GovCloud CIDR (verify for your region)
      ports:
        - protocol: TCP
          port: 443
    
    # NO internet egress - deny-all handles this
```

### Allow PgBouncer Ingress

**base/network-policies/pgbouncer-allow-ingress.yaml:**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: pgbouncer-allow-ingress
  namespace: cockroachdb
spec:
  podSelector:
    matchLabels:
      app: pgbouncer
  policyTypes:
    - Ingress
  ingress:
    # Allow from application namespaces only on port 5432
    - from:
        - namespaceSelector:
            matchLabels:
              app: application  # Application namespaces must have this label
      ports:
        - protocol: TCP
          port: 5432
    
    # Allow from monitoring for metrics
    - from:
        - namespaceSelector:
            matchLabels:
              name: monitoring
      ports:
        - protocol: TCP
          port: 9127  # PgBouncer exporter port (if deployed)
```

### Allow PgBouncer Egress

**base/network-policies/pgbouncer-allow-egress.yaml:**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: pgbouncer-allow-egress
  namespace: cockroachdb
spec:
  podSelector:
    matchLabels:
      app: pgbouncer
  policyTypes:
    - Egress
  egress:
    # Allow to CRDB pods on port 26257
    - to:
        - podSelector:
            matchLabels:
              app: cockroachdb-east
      ports:
        - protocol: TCP
          port: 26257
    
    # Allow DNS
    - to:
        - namespaceSelector:
            matchLabels:
              name: kube-system
      ports:
        - protocol: UDP
          port: 53
```

Deploy via ArgoCD:

```bash
kubectl apply -f clusters/east/argocd-apps/network-policies.yaml --context crdb-dcp-east
```

---

## Encryption-at-Rest

Two layers of encryption for defense-in-depth:

### Layer 1: EBS Volume Encryption (AWS KMS)

Already configured in the StorageClass (see [EKS Cluster Setup](#eks-cluster-setup-3-az-topology)):

```yaml
parameters:
  encrypted: "true"
  kmsKeyId: "arn:aws-us-gov:kms:us-gov-east-1:123456789012:key/<key-id>"
```

### Layer 2: CockroachDB Encryption-at-Rest

Configure in the CockroachDB Custom Resource:

**Update base/cockroachdb-cluster/crdb-east.yaml:**

```yaml
spec:
  # ... existing config ...
  
  # Enterprise encryption-at-rest
  additionalArgs:
    - --enterprise-encryption=path=/cockroach/cockroach-data,key=/cockroach/cockroach-keys/master.key,old-key=plain
  
  # Mount encryption key from secret
  additionalVolumes:
    - name: encryption-key
      secret:
        secretName: cockroachdb-encryption-key
  
  additionalVolumeMounts:
    - name: encryption-key
      mountPath: /cockroach/cockroach-keys
      readOnly: true
```

### Generate Encryption Key

```bash
# Generate 128-bit AES key
cockroach gen encryption-key -s 128 /tmp/master.key

# Create Kubernetes secret
kubectl create secret generic cockroachdb-encryption-key \
  --from-file=master.key=/tmp/master.key \
  -n cockroachdb \
  --context crdb-dcp-east

# Securely delete local copy
shred -u /tmp/master.key
```

**For GitOps/production**, store the key in Vault and inject via External Secrets Operator (similar to license injection).

### Verify Encryption

```bash
kubectl exec -it cockroachdb-east-0 -n cockroachdb --context crdb-dcp-east -- \
  cockroach debug encryption-active-key /cockroach/cockroach-data --certs-dir=/cockroach/cockroach-certs

# Expected output:
#   /cockroach/cockroach-data: aes-128-ctr (ID: master, created: 2026-06-03 12:00:00)
```

---

## Audit Log Pipeline

Stream CockroachDB SENSITIVE_ACCESS audit logs to S3 with Object Lock (WORM) for compliance.

### 1. Enable Audit Logging

```bash
kubectl exec -it cockroachdb-east-0 -n cockroachdb --context crdb-dcp-east -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost <<EOF
SET CLUSTER SETTING sql.log.user_audit = 'SENSITIVE_ACCESS';
ALTER ROLE ALL SET CLUSTER SETTING sql.log.user_audit = 'SENSITIVE_ACCESS';
EOF
```

### 2. Deploy Fluent Bit DaemonSet

**base/fluent-bit/configmap.yaml:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: cockroachdb
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush         5
        Daemon        off
        Log_Level     info
        Parsers_File  parsers.conf

    [INPUT]
        Name              tail
        Path              /var/log/pods/cockroachdb_cockroachdb-east-*/*/*.log
        Parser            docker
        Tag               kube.*
        Refresh_Interval  5
        Mem_Buf_Limit     5MB
        Skip_Long_Lines   On

    [FILTER]
        Name                kubernetes
        Match               kube.*
        Kube_URL            https://kubernetes.default.svc:443
        Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
        Merge_Log           On
        K8S-Logging.Parser  On
        K8S-Logging.Exclude Off

    [FILTER]
        Name    grep
        Match   kube.*
        Regex   log SENSITIVE_ACCESS

    [OUTPUT]
        Name                         s3
        Match                        kube.*
        bucket                       crdb-audit-logs-govcloud-east
        region                       us-gov-east-1
        endpoint                     s3.us-gov-east-1.amazonaws.com
        s3_key_format                /audit-logs/%Y/%m/%d/%H/%M/%S-$UUID.log
        total_file_size              10M
        upload_timeout               1m
        use_put_object               On
        compression                  gzip
        store_dir                    /tmp/fluent-bit/s3
        
  parsers.conf: |
    [PARSER]
        Name   docker
        Format json
        Time_Key time
        Time_Format %Y-%m-%dT%H:%M:%S.%LZ
```

**base/fluent-bit/daemonset.yaml:**

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluent-bit
  namespace: cockroachdb
spec:
  selector:
    matchLabels:
      app: fluent-bit
  template:
    metadata:
      labels:
        app: fluent-bit
    spec:
      serviceAccountName: fluent-bit
      containers:
        - name: fluent-bit
          image: 123456789012.dkr.ecr.us-gov-east-1.amazonaws.com/fluent-bit:3.0.2
          volumeMounts:
            - name: config
              mountPath: /fluent-bit/etc/
            - name: varlog
              mountPath: /var/log
            - name: varlibdockercontainers
              mountPath: /var/lib/docker/containers
              readOnly: true
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
      volumes:
        - name: config
          configMap:
            name: fluent-bit-config
        - name: varlog
          hostPath:
            path: /var/log
        - name: varlibdockercontainers
          hostPath:
            path: /var/lib/docker/containers
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
```

### 3. Create IRSA for S3 Access

```bash
# Create IAM policy for S3 audit log write
cat > audit-log-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:PutObjectAcl"
      ],
      "Resource": "arn:aws-us-gov:s3:::crdb-audit-logs-govcloud-east/*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name CockroachDBAuditLogWrite \
  --policy-document file://audit-log-policy.json \
  --region us-gov-east-1 \
  --profile govcloud-revenue

# Create IRSA
eksctl create iamserviceaccount \
  --cluster=crdb-dcp-east \
  --namespace=cockroachdb \
  --name=fluent-bit \
  --attach-policy-arn=arn:aws-us-gov:iam::123456789012:policy/CockroachDBAuditLogWrite \
  --override-existing-serviceaccounts \
  --region us-gov-east-1 \
  --profile govcloud-revenue \
  --approve
```

### 4. Deploy via ArgoCD

```bash
kubectl apply -f clusters/east/argocd-apps/fluent-bit.yaml --context crdb-dcp-east
```

### 5. Verify Audit Log Pipeline

```bash
# Check Fluent Bit pods
kubectl get pods -n cockroachdb -l app=fluent-bit --context crdb-dcp-east

# Verify logs in S3
aws s3 ls s3://crdb-audit-logs-govcloud-east/audit-logs/ --region us-gov-east-1 --profile govcloud-revenue --recursive

# Check Object Lock status
aws s3api get-object-retention \
  --bucket crdb-audit-logs-govcloud-east \
  --key audit-logs/<path-to-log-file> \
  --region us-gov-east-1 \
  --profile govcloud-revenue
```

---

## Scheduling Automated Backups

Configure automated backups to S3 using IRSA.

### 1. Create IRSA for S3 Backup Access

```bash
# Create IAM policy for S3 backup
cat > backup-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws-us-gov:s3:::crdb-backups-govcloud-east",
        "arn:aws-us-gov:s3:::crdb-backups-govcloud-east/*"
      ]
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name CockroachDBBackupAccess \
  --policy-document file://backup-policy.json \
  --region us-gov-east-1 \
  --profile govcloud-revenue

# Create IRSA for CockroachDB pods
eksctl create iamserviceaccount \
  --cluster=crdb-dcp-east \
  --namespace=cockroachdb \
  --name=cockroachdb-sa \
  --attach-policy-arn=arn:aws-us-gov:iam::123456789012:policy/CockroachDBBackupAccess \
  --override-existing-serviceaccounts \
  --region us-gov-east-1 \
  --profile govcloud-revenue \
  --approve
```

### 2. Update CockroachDB CR to Use IRSA

**Update base/cockroachdb-cluster/crdb-east.yaml:**

```yaml
spec:
  # ... existing config ...
  serviceAccountName: cockroachdb-sa  # IRSA service account
```

### 3. Create Backup Schedule

```bash
# Note: Use GovCloud S3 endpoint explicitly
kubectl exec -it cockroachdb-east-0 -n cockroachdb --context crdb-dcp-east -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost -e """
CREATE SCHEDULE crdb_daily_backup
  FOR BACKUP INTO 's3://crdb-backups-govcloud-east/scheduled?AWS_ENDPOINT=s3.us-gov-east-1.amazonaws.com&AUTH=implicit'
  RECURRING '@daily'
  FULL BACKUP '@weekly'
  WITH SCHEDULE OPTIONS first_run = 'now';
"""

# Verify schedule
kubectl exec -it cockroachdb-east-0 -n cockroachdb --context crdb-dcp-east -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost -e "SHOW SCHEDULES;"
```

**Important**: The `AWS_ENDPOINT=s3.us-gov-east-1.amazonaws.com` parameter is required for GovCloud S3 access.

### 4. Verify Backups

```bash
# Check backups in S3
aws s3 ls s3://crdb-backups-govcloud-east/scheduled/ --region us-gov-east-1 --profile govcloud-revenue --recursive

# Show backup details in SQL
kubectl exec -it cockroachdb-east-0 -n cockroachdb --context crdb-dcp-east -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost -e \
  "SHOW BACKUPS IN 's3://crdb-backups-govcloud-east/scheduled?AWS_ENDPOINT=s3.us-gov-east-1.amazonaws.com&AUTH=implicit';"
```

---

## Monitoring with Prometheus and Grafana

Deploy Prometheus and Grafana for observability.

### Install Prometheus Operator (kube-prometheus-stack)

```bash
# Add Prometheus community Helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install kube-prometheus-stack
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set grafana.adminPassword=admin \
  --context crdb-dcp-east
```

### Create ServiceMonitor for CockroachDB

**base/monitoring/crdb-servicemonitor.yaml:**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: cockroachdb-metrics
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: cockroachdb-east
  namespaceSelector:
    matchNames:
      - cockroachdb
  endpoints:
    - port: http
      interval: 30s
      path: /_status/vars
```

### Import CockroachDB Grafana Dashboards

```bash
# Download official dashboards
curl -O https://raw.githubusercontent.com/cockroachdb/cockroach/master/monitoring/grafana-dashboards/runtime.json
curl -O https://raw.githubusercontent.com/cockroachdb/cockroach/master/monitoring/grafana-dashboards/storage.json
curl -O https://raw.githubusercontent.com/cockroachdb/cockroach/master/monitoring/grafana-dashboards/sql.json

# Import to Grafana via UI or ConfigMap
kubectl create configmap crdb-dashboards \
  --from-file=runtime.json \
  --from-file=storage.json \
  --from-file=sql.json \
  -n monitoring \
  --context crdb-dcp-east
```

### Access Grafana

```bash
# Port-forward to Grafana
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring --context crdb-dcp-east

# Open browser
open http://localhost:3000
# Login: admin / admin
```

### Key Metrics to Monitor

- **Replication Lag (PCR)**: `SELECT lag FROM [SHOW VIRTUAL CLUSTER main WITH REPLICATION STATUS]`
- **Clock Offset**: `clock_offset_meannanos / 1000000 > 400` (alert if > 400ms)
- **Under-Replicated Ranges**: `ranges_underreplicated > 0`
- **Disk Usage**: `(capacity - available) / capacity > 0.8`
- **Query Latency P99**: `histogram_quantile(0.99, rate(sql_exec_latency_bucket[5m]))`

---

## Common Operations

### Accessing SQL Shell

```bash
# Via kubectl exec
kubectl exec -it cockroachdb-east-0 -n cockroachdb --context crdb-dcp-east -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost --database=defaultdb

# Connect to virtual cluster
kubectl exec -it cockroachdb-east-0 -n cockroachdb --context crdb-dcp-east -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost --cluster=main --database=defaultdb

# Via port-forward (external access)
kubectl port-forward svc/cockroachdb-east-public 26257:26257 -n cockroachdb --context crdb-dcp-east
cockroach sql --url "postgresql://root@localhost:26257/defaultdb?sslmode=verify-full&sslrootcert=/path/to/ca.crt&sslcert=/path/to/client.root.crt&sslkey=/path/to/client.root.key&options=-ccluster=main"
```

### Viewing Logs

```bash
# CockroachDB logs
kubectl logs -f cockroachdb-east-0 -n cockroachdb --context crdb-dcp-east

# PgBouncer logs
kubectl logs -f -l app=pgbouncer -n cockroachdb --context crdb-dcp-east

# Fluent Bit logs (audit pipeline)
kubectl logs -f -l app=fluent-bit -n cockroachdb --context crdb-dcp-east
```

### Scaling the Cluster

Scaling is done via Git PR → ArgoCD sync (GitOps workflow):

1. **Update the CockroachDB CR** in Git:

```yaml
# base/cockroachdb-cluster/crdb-east.yaml
spec:
  nodes: 5  # Scale from 3 to 5
```

2. **Commit and push** to Git repository

3. **ArgoCD syncs automatically** or manually trigger:

```bash
argocd app sync cockroachdb-cluster-east --context crdb-dcp-east
```

4. **Verify scaling**:

```bash
kubectl get pods -n cockroachdb --context crdb-dcp-east
# Expected: cockroachdb-east-0 through cockroachdb-east-4
```

### Checking Cluster Health

```bash
kubectl exec -it cockroachdb-east-0 -n cockroachdb --context crdb-dcp-east -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost -e """
SELECT node_id, address, is_live, is_available FROM crdb_internal.gossip_nodes;
SHOW CLUSTER SETTING cluster.organization;
SHOW VIRTUAL CLUSTER main WITH REPLICATION STATUS;
"""
```

---

## Failover and Failback Procedures

### Failover: Promote West to Active

When East region fails, promote West cluster to serve traffic:

1. **Complete replication to latest**:

```bash
kubectl exec -it cockroachdb-west-0 -n cockroachdb --context crdb-dcp-west -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost -e """
ALTER VIRTUAL CLUSTER main COMPLETE REPLICATION TO LATEST;
"""
```

This command waits for West to catch up to the last replicated timestamp from East before proceeding.

2. **Start service on West virtual cluster**:

```bash
kubectl exec -it cockroachdb-west-0 -n cockroachdb --context crdb-dcp-west -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost -e """
ALTER VIRTUAL CLUSTER main START SERVICE SHARED;
"""
```

Now West is serving read/write traffic.

3. **Update application connection strings** to point to West:

```
postgresql://root@pgbouncer.us-gov-west-1.dcp-govcloud.example.com:5432/defaultdb?sslmode=verify-full&options=-ccluster=main
```

Or update DNS to point to West NLB.

4. **Verify West is active**:

```bash
kubectl exec -it cockroachdb-west-0 -n cockroachdb --context crdb-dcp-west -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost -e """
SHOW VIRTUAL CLUSTER main WITH REPLICATION STATUS;
"""

# Expected:
#   service_mode: shared (was 'none' before)
#   data_state: ready (no longer 'replicating')
```

### Failback: Restore East as Active

After East region is restored, reverse the replication:

1. **On East, create virtual cluster from West replication**:

```bash
kubectl exec -it cockroachdb-east-0 -n cockroachdb --context crdb-dcp-east -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost -e """
CREATE VIRTUAL CLUSTER main FROM REPLICATION OF main ON 'postgresql://cockroachdb-west-public.cockroachdb.svc.cluster.local:26257?sslmode=verify-full&sslrootcert=/cockroach/cockroach-certs/ca.crt&sslcert=/cockroach/cockroach-certs/client.root.crt&sslkey=/cockroach/cockroach-certs/client.root.key';
"""
```

2. **Wait for East to catch up**:

```bash
kubectl exec -it cockroachdb-east-0 -n cockroachdb --context crdb-dcp-east -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost -e """
SHOW VIRTUAL CLUSTER main WITH REPLICATION STATUS;
"""

# Wait for replication_lag < 5 seconds
```

3. **Cutover: Stop service on West, start on East**:

```bash
# Stop West
kubectl exec -it cockroachdb-west-0 -n cockroachdb --context crdb-dcp-west -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost -e """
ALTER VIRTUAL CLUSTER main STOP SERVICE;
"""

# Complete replication on East
kubectl exec -it cockroachdb-east-0 -n cockroachdb --context crdb-dcp-east -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost -e """
ALTER VIRTUAL CLUSTER main COMPLETE REPLICATION TO LATEST;
"""

# Start East
kubectl exec -it cockroachdb-east-0 -n cockroachdb --context crdb-dcp-east -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost -e """
ALTER VIRTUAL CLUSTER main START SERVICE SHARED;
"""
```

4. **Update application connection strings** back to East.

5. **Re-establish West as passive replica** (repeat PCR setup from East → West).

---

## Security Notes

### mTLS Everywhere

- All CockroachDB node-to-node communication uses mTLS (Vault PKI-issued certs)
- All client-to-node communication requires client certificates
- PgBouncer-to-CRDB uses client certificates
- Application-to-PgBouncer uses client certificates

### Network Policies

- Deny-all default with explicit allow rules
- No pod-to-internet egress (GovCloud compliance)
- Cross-region traffic allowed only for PCR replication

### IRSA (IAM Roles for Service Accounts)

- No AWS credentials stored in pods or secrets
- Service accounts have IAM roles attached via OIDC
- Least-privilege policies for S3 backup and audit log access

### Audit Logging

- SENSITIVE_ACCESS logs streamed to S3 with Object Lock (WORM)
- 7-year retention (2555 days) for compliance
- Separate bucket from backups

### Encryption-at-Rest

- Layer 1: EBS volumes encrypted with customer-managed KMS keys
- Layer 2: CockroachDB encryption-at-rest with per-node AES-128 keys
- Enterprise license required for database-level encryption

---

## Troubleshooting

### Pods Not Starting

```bash
# Check pod events
kubectl describe pod <pod-name> -n cockroachdb --context crdb-dcp-east

# Common issues:
# - Image pull errors (ECR mirroring incomplete)
# - PVC stuck in pending (EBS CSI driver not installed, wrong StorageClass)
# - Pod anti-affinity conflicts (not enough nodes in each AZ)
```

### PVC Stuck in Pending

```bash
# Check PVC status
kubectl get pvc -n cockroachdb --context crdb-dcp-east

# Check events
kubectl describe pvc <pvc-name> -n cockroachdb --context crdb-dcp-east

# Common causes:
# - StorageClass doesn't exist or is misspelled
# - EBS CSI driver not installed
# - volumeBindingMode is Immediate but pod not scheduled (should be WaitForFirstConsumer)
# - KMS key permissions issue
```

### LoadBalancer Not Getting External IP

```bash
# Check service
kubectl get svc <service-name> -n cockroachdb --context crdb-dcp-east

# Check AWS Load Balancer Controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --context crdb-dcp-east

# Common causes:
# - AWS LB Controller not installed
# - Subnets not tagged correctly for EKS
# - Security groups blocking traffic
```

### Replication Lag High

```bash
# Check replication status
kubectl exec -it cockroachdb-west-0 -n cockroachdb --context crdb-dcp-west -- \
  cockroach sql --certs-dir=/cockroach/cockroach-certs --host=localhost -e \
  "SHOW VIRTUAL CLUSTER main WITH REPLICATION STATUS;"

# Common causes:
# - Network latency between regions (check Transit Gateway routes)
# - East cluster overloaded (scale up)
# - Rangefeed not enabled on East
# - Network policy blocking cross-region traffic on port 26257
```

### Certificate Issues

```bash
# Check cert-manager certificates
kubectl get certificate -n cockroachdb --context crdb-dcp-east
kubectl describe certificate <cert-name> -n cockroachdb --context crdb-dcp-east

# Check Vault issuer
kubectl get clusterissuer vault-issuer -o yaml --context crdb-dcp-east

# Common causes:
# - Vault auth role misconfigured
# - Vault policy doesn't allow cert issuance
# - cert-manager service account doesn't have correct annotations for Vault auth
```

### Audit Logs Not Appearing in S3

```bash
# Check Fluent Bit pods
kubectl get pods -n cockroachdb -l app=fluent-bit --context crdb-dcp-east
kubectl logs -f <fluent-bit-pod> -n cockroachdb --context crdb-dcp-east

# Check IRSA
kubectl describe sa fluent-bit -n cockroachdb --context crdb-dcp-east
# Should have eks.amazonaws.com/role-arn annotation

# Common causes:
# - IRSA not configured or service account not annotated
# - S3 bucket policy doesn't allow IRSA role
# - Fluent Bit config syntax error (check ConfigMap)
# - Network policy blocking S3 egress
```

---

## Next Steps

- [ ] Test PCR failover and failback procedures in dev environment
- [ ] Load test cluster with production-like workload
- [ ] Configure CloudWatch/Datadog alerts for replication lag, disk usage, clock offset
- [ ] Document runbook for incident response
- [ ] Review CockroachDB production checklist: https://www.cockroachlabs.com/docs/stable/recommended-production-settings
- [ ] Plan for certificate rotation testing
- [ ] Set up automated backup restore testing

For questions or issues, refer to:
- CockroachDB Operator docs: https://www.cockroachlabs.com/docs/stable/kubernetes-overview
- CockroachDB PCR docs: https://www.cockroachlabs.com/docs/stable/physical-cluster-replication-overview
- CockroachDB docs: https://www.cockroachlabs.com/docs/
- Community forum: https://forum.cockroachlabs.com/
