# AWS EKS Reference Architecture

This reference architecture deploys a **production-ready, cloud-native** CockroachDB cluster with distributed connection pooling on AWS EKS (Elastic Kubernetes Service) using the CockroachDB Operator.

## Overview

**Architecture Components:**
- **EKS Cluster**: Managed Kubernetes control plane with multi-AZ worker nodes
- **CockroachDB Operator**: Kubernetes operator for automated CRDB lifecycle management
- **CockroachDB StatefulSet**: Database tier with persistent volumes and pod anti-affinity
- **PgBouncer Deployment**: Connection pooling layer deployed as Kubernetes pods
- **LoadBalancer Services**: AWS NLB/ALB for external access to PgBouncer and DB Console
- **IAM Roles for Service Accounts (IRSA)**: S3 access for backups without hardcoded credentials

**Security Features:**
- **EBS Encryption**: AWS KMS-encrypted EBS volumes for persistent storage
- **CockroachDB Encryption-at-Rest**: Database-level encryption (Enterprise license required)
- **Network Policies**: Pod-to-pod communication restrictions
- **TLS Certificates**: Mutual TLS for node-to-node and client-to-node communication
- **IRSA for S3**: IAM roles attached to service accounts for secure S3 access
- **Private Subnets**: Worker nodes in private subnets with NAT gateway for outbound

**Key Differences from EC2 Architecture:**
- Kubernetes-native resource management vs. EC2 instances
- CockroachDB Operator automates cluster lifecycle (scaling, upgrades, failover)
- Kubernetes Services replace HAProxy + Keepalived for load balancing
- StatefulSets with PersistentVolumeClaims instead of EC2 EBS volumes
- kubectl/Helm-based deployment instead of Terraform + cloud-init
- No bastion hosts needed - `kubectl port-forward` or exec for admin access

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [EKS Cluster Setup](#eks-cluster-setup)
- [CockroachDB Operator Installation](#cockroachdb-operator-installation)
- [CockroachDB Cluster Deployment](#cockroachdb-cluster-deployment)
- [PgBouncer Deployment](#pgbouncer-deployment)
- [Load Balancing and External Access](#load-balancing-and-external-access)
- [Encryption-at-Rest](#encryption-at-rest)
- [Scheduling Automated Backups](#scheduling-automated-backups)
- [Monitoring with Prometheus and Grafana](#monitoring-with-prometheus-and-grafana)
- [Multi-Region Configuration](#multi-region-configuration-optional)
- [Common Operations](#common-operations)
- [Security Notes](#security-notes)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Tools and CLI Setup

**Required tools:**
- `kubectl` - Kubernetes command-line tool
- `helm` - Kubernetes package manager
- `eksctl` or Terraform - for EKS cluster provisioning
- `aws` CLI - for AWS resource management
- `jq` - JSON parsing

**Installation:**

```bash
# macOS
brew install kubectl helm eksctl awscli jq

# Linux
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# eksctl
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

# jq
sudo apt-get install jq  # or yum install jq
```

### AWS Account Setup

<details>
<summary>AWS CLI and SSO Configuration (click to expand)</summary>

**Configure AWS SSO and verify access:**

```bash
# Login via SSO
aws sso login --profile crl-revenue

# Verify access
aws eks list-clusters --region us-east-2
```

</details>

### IAM Permissions

Ensure your AWS user/role has permissions for:
- EKS cluster creation and management
- EC2 (for worker nodes, VPC, subnets, security groups)
- IAM (for IRSA - IAM Roles for Service Accounts)
- S3 (for backups bucket creation)
- Route53 (optional, for DNS)

### Checklist

Before deploying, ensure:

- ✅ AWS credentials configured and tested
- ✅ kubectl, helm, eksctl, aws CLI installed
- ✅ IAM permissions for EKS, EC2, IAM, S3
- ✅ Route53 public hosted zone created (optional for DNS-based access)
- ✅ Decide on single-region or multi-region deployment

---

## EKS Cluster Setup

### Option 1: Using eksctl (Recommended for Quick Start)

Create an EKS cluster with managed node groups:

```bash
# TODO: eksctl cluster configuration
```

### Option 2: Using Terraform (Recommended for Production)

Use Terraform to provision EKS with fine-grained control:

```bash
# TODO: Terraform EKS module configuration
```

**Cluster configuration considerations:**
- Multi-AZ node groups for high availability
- Private subnets for worker nodes (with NAT gateway)
- Public subnets for load balancers
- EBS CSI driver for persistent volumes
- Cluster autoscaler (optional)
- AWS Load Balancer Controller

---

## CockroachDB Operator Installation

The CockroachDB Kubernetes Operator automates cluster deployment, scaling, upgrades, and certificate management.

### Install the Operator

```bash
# TODO: Operator installation via Helm or kubectl apply
```

### Verify Installation

```bash
# TODO: Verification commands
```

---

## CockroachDB Cluster Deployment

Deploy a CockroachDB cluster using a custom resource manifest:

### Create Namespace and Configure Storage

```bash
# TODO: Namespace creation and StorageClass configuration
```

### Deploy CockroachDB Custom Resource

```bash
# TODO: CockroachDB CR YAML and deployment
```

### Initialize the Cluster

```bash
# TODO: Cluster initialization via operator
```

### Verify Cluster Health

```bash
# TODO: Health check commands
```

---

## PgBouncer Deployment

Deploy PgBouncer as a Kubernetes Deployment for connection pooling:

### Create PgBouncer ConfigMap

```bash
# TODO: PgBouncer configuration
```

### Deploy PgBouncer

```bash
# TODO: PgBouncer Deployment YAML
```

### Verify PgBouncer

```bash
# TODO: Verification commands
```

---

## Load Balancing and External Access

Expose PgBouncer and CockroachDB DB Console via Kubernetes Services:

### Create LoadBalancer Services

```bash
# TODO: Service YAML for PgBouncer (NLB)
# TODO: Service YAML for DB Console (NLB)
```

### Configure DNS (Optional)

```bash
# TODO: Route53 DNS configuration pointing to NLB
```

---

## Encryption-at-Rest

Configure two layers of encryption:

### Layer 1: EBS Volume Encryption (AWS KMS)

```bash
# TODO: EBS encryption configuration in StorageClass
```

### Layer 2: CockroachDB Encryption-at-Rest

```bash
# TODO: Enterprise encryption configuration in CockroachDB CR
# TODO: License application
```

---

## Scheduling Automated Backups

Configure automated backups to S3 using IRSA:

### Create S3 Bucket and IAM Role

```bash
# TODO: S3 bucket creation
# TODO: IRSA configuration
```

### Configure Backup Schedule

```bash
# TODO: CockroachDB backup CronJob or schedule
```

---

## Monitoring with Prometheus and Grafana

Deploy Prometheus and Grafana for observability:

### Install Prometheus Operator

```bash
# TODO: Prometheus operator installation
```

### Configure ServiceMonitor for CockroachDB

```bash
# TODO: ServiceMonitor YAML
```

### Import Grafana Dashboards

```bash
# TODO: Grafana dashboard import
```

---

## Multi-Region Configuration (Optional)

Deploy CockroachDB across multiple EKS clusters for multi-region:

### Architecture Considerations

```bash
# TODO: Multi-cluster federation approach
# TODO: VPC peering or Transit Gateway
```

---

## Common Operations

### Accessing SQL Shell

```bash
# Via kubectl exec
kubectl exec -it cockroachdb-0 -n cockroachdb -- cockroach sql --certs-dir=/cockroach/cockroach-certs

# Via port-forward
kubectl port-forward svc/cockroachdb-public 26257:26257 -n cockroachdb
cockroach sql --url "postgresql://localhost:26257/defaultdb?sslmode=verify-full" --certs-dir=./certs
```

### Viewing Logs

```bash
# CockroachDB logs
kubectl logs -f cockroachdb-0 -n cockroachdb

# PgBouncer logs
kubectl logs -f -l app=pgbouncer -n cockroachdb
```

### Scaling the Cluster

```bash
# Scale CockroachDB nodes
kubectl patch crdbcluster cockroachdb -n cockroachdb --type='json' -p='[{"op": "replace", "path": "/spec/nodes", "value": 5}]'
```

---

## Security Notes

### Network Policies

```bash
# TODO: NetworkPolicy YAML for pod isolation
```

### IRSA (IAM Roles for Service Accounts)

```bash
# TODO: IRSA configuration for S3 access
```

### Certificate Management

```bash
# TODO: Cert-manager or operator-managed certificates
```

---

## Troubleshooting

### Common Issues

**Pods not starting:**
```bash
# TODO: Diagnostic commands
```

**PVC stuck in pending:**
```bash
# TODO: EBS CSI driver troubleshooting
```

**LoadBalancer not getting external IP:**
```bash
# TODO: AWS LB controller troubleshooting
```

---

## Next Steps

- [ ] Configure TLS certificates for production use
- [ ] Set up CloudWatch/Datadog alerts
- [ ] Test backup/restore procedures
- [ ] Load test the cluster
- [ ] Review CockroachDB production checklist

For questions or issues, refer to:
- CockroachDB Operator docs: https://www.cockroachlabs.com/docs/stable/kubernetes-overview
- CockroachDB docs: https://www.cockroachlabs.com/docs/
- Community forum: https://forum.cockroachlabs.com/
