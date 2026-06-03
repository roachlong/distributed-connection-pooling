# AWS EKS Reference Architecture

Production-ready deployment of CockroachDB with distributed connection pooling on AWS EKS using the CockroachDB Kubernetes Operator.

## Quick Links

- **[Full Deployment Guide](./DEPLOYMENT.md)** - Complete setup instructions
- **[Kubernetes Manifests](./manifests/)** - YAML configurations (coming soon)
- **[Helm Charts](./helm/)** - Helm-based deployments (coming soon)

## Overview

This reference architecture demonstrates how to deploy a highly available, cloud-native CockroachDB cluster with PgBouncer connection pooling on AWS EKS.

**Key Features:**
- Kubernetes-native deployment using CockroachDB Operator
- Automated cluster lifecycle management (scaling, upgrades, failover)
- PgBouncer for connection pooling
- AWS Network Load Balancer for external access
- EBS encryption + CockroachDB encryption-at-rest
- IRSA for secure S3 backup access
- Multi-AZ deployment for high availability

**Compared to EC2 Architecture:**
- Simpler operational model with Kubernetes abstractions
- Automated cluster management via operator
- Container-based deployment instead of VMs
- Kubernetes Services instead of HAProxy + Keepalived
- kubectl-based administration instead of SSH

## Prerequisites

- AWS account with EKS permissions
- kubectl, helm, eksctl, aws CLI installed
- Basic Kubernetes knowledge

## Getting Started

See the [Deployment Guide](./DEPLOYMENT.md) for complete setup instructions.

## Directory Structure

```
kubernetes/eks/
├── DEPLOYMENT.md          # Complete deployment guide
├── README.md              # This file
├── manifests/             # Kubernetes YAML manifests (coming soon)
│   ├── namespace.yaml
│   ├── cockroachdb-cr.yaml
│   ├── pgbouncer-deployment.yaml
│   └── services.yaml
└── helm/                  # Helm chart (coming soon)
    └── dcp-crdb/
```
