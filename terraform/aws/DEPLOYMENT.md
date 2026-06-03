# AWS EC2 Reference Architecture

This reference architecture deploys a **production-ready, compliance-focused** multi-region CockroachDB cluster with distributed connection pooling on AWS EC2. The architecture uses **defense-in-depth** with layered security.

## Overview

**Network Architecture:**
- **CRDB Nodes (Private Subnets)**: Database tier isolated from internet with no direct public access
- **DCP Nodes (Public Subnets)**: Connection pooling layer (PgBouncer + HAProxy) acts as the client entry point
- **Bastion Hosts (Public Subnets)**: Jump hosts for SSH access to private CRDB nodes
- **NAT Gateway**: Provides outbound-only internet for private subnets (package installations, binary downloads)

**Security Features:**
- **Defense-in-Depth Encryption**:
  - **Layer 1 (EBS)**: AWS KMS-encrypted EBS volumes with customer-managed keys and auto-rotation
  - **Layer 2 (Database)**: CockroachDB encryption-at-rest with per-node AES-128 keys (Enterprise license required)
- **IAM Instance Profiles**: S3 access for IMPORT, BACKUP, and audit logs using implicit auth (no credentials in connection strings)
- **NTP Synchronization**: Chrony configured with AWS Time Sync Service to maintain clock offset < 500ms (required for CRDB)
- **Security Groups**: CRDB nodes only accept connections from DCP nodes + bastion; DCP nodes accept client connections from allowed IPs
- **Automated Initialization**: Script-based cluster bootstrap with locality-aware replica placement

**Management Access:**
- **controller.py** → DCP nodes (public IPs) for PgBouncer configuration management
- **Bastion (ProxyCommand)** → CRDB nodes (private IPs) for database administration
- **Clients** → DCP VIP/EIP (public) → PgBouncer → CRDB (private)

---

## Deployment Options

There are two deployment approaches available:

**Option 1: Automated Deployment with controller.py** (Recommended)
- End-to-end automation: Terraform → certificates → cluster init → PgBouncer config
- Idempotent - can be re-run to update connection pool settings
- Handles the full workflow from infrastructure to working cluster
- **Use this approach for quick setup and iterative pool configuration changes**

**Option 2: Manual Terraform Workflow** (Maximum control)
- Step-by-step control over each deployment phase
- Useful for understanding the architecture or customizing the process
- Documented in [Manual Deployment](#manual-deployment-workflow) below

**Both approaches create the same infrastructure:**
- CRDB nodes in **private subnets** (no direct internet access)
- DCP nodes in **public subnets** (client entry point)
- Bastion hosts for SSH access to private nodes
- S3 buckets for backups/imports/audit logs (automatic)
- **Two layers of encryption** (automatic):
  - **EBS encryption** (AWS KMS) - protects storage devices
  - **Database encryption** (CockroachDB) - protects data files, backups, exports
- NAT Gateway for private subnet outbound internet (automatic)

**Encryption activation:**
- Add `cockroach_organization` and `cockroach_license` to your tfvars
- Init script automatically applies license during cluster initialization
- Encryption-at-rest activates immediately
- Without license: only EBS encryption is active (Layer 1 only)

No additional tfvars required beyond `permissions_boundary_arn` and optional `cockroach_license` - all security features are provisioned automatically.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Automated Deployment with controller.py](#automated-deployment-with-controllerpy)
- [Manual Deployment Workflow](#manual-deployment-workflow)
- [Managing Your Deployment](#managing-your-deployment)
- [Architecture Details](#architecture-details)
- [SSH Access to Private CRDB Nodes](#ssh-access-to-private-crdb-nodes)
- [Cluster Initialization](#cluster-initialization)
- [Encryption-at-Rest](#encryption-at-rest)
- [Scheduling Automated Backups](#scheduling-automated-backups)
- [Monitoring with Prometheus and Grafana](#monitoring-with-prometheus-and-grafana)
- [Multi-Region Configuration](#multi-region-configuration-optional)
- [Common Operations](#common-operations)
- [Security Notes](#security-notes)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

Before proceeding, ensure:

1. ✅ AWS credentials configured (`aws sso login` or similar)
2. ✅ Route53 public hosted zone created for DNS (optional but recommended)
3. ✅ SSH key pair generated and imported to AWS regions
4. ✅ `jq` installed for JSON parsing: `brew install jq` (macOS) or `apt install jq` (Linux)

For manual Terraform workflow, additionally ensure:
- ✅ `terraform apply` completed successfully
- ✅ SSH key configured and accessible at `~/.ssh/<your-key>.pem`
- ✅ Your SSH IP is allowed in the `ssh_ip_range` variable (for DCP and bastion access)

---

## Automated Deployment with controller.py

The controller orchestrates the entire deployment process. It will:
1. Run `terraform apply` to provision infrastructure
2. Generate and distribute TLS certificates
3. Initialize the CockroachDB cluster
4. Configure PgBouncer connection pools
5. Setup HAProxy load balancing

### Step 1: Create your tfvars configuration

```bash
# Find your public IP for ssh_ip_range (bastion + DCP access)
dig +short myip.opendns.com @resolver1.opendns.com

# Create SSH key pair for EC2 instances
ssh-keygen -b 2048 -f ./my-safe-directory/dev
aws ec2 import-key-pair \
  --key-name dev \
  --public-key-material fileb://./my-safe-directory/dev.pub \
  --region us-east-2

# Create your tfvars configuration
cat <<'EOF' > ./terraform/aws/crdb-dcp-test.tfvars
project_name = "crdb-dcp-test"
project_tags = {
    Project = "crdb-dcp-test"
}
dns_zone = "dcp-test.crdb.com"
public_zone_id = "Z09942323KHF5XIP6R8IR"
enabled_regions = ["us-east-2"]
vpc_cidrs = {
    us-east-1 = "10.10.0.0/16"
    us-east-2 = "10.20.0.0/16"
    us-west-1 = "10.30.0.0/16"
    us-west-2 = "10.40.0.0/16"
}
ssh_ip_range = "xxx.xxx.xxx.xxx/32"  # Your public IP for bastion SSH access
ssh_key_name = "dev"

nodes_per_region = 1
az_count = 1
vm_user = "debian"
permissions_boundary_arn = "arn:aws:iam::<ACCOUNT_ID>:policy/<YourPermissionsBoundary>"

# Use existing IAM instance profile instead of creating new one
# If your SSO role lacks iam:CreateRole permissions, use an existing profile
existing_iam_instance_profile_name = "your-existing-profile"  # Optional

cockroach_version = "25.4.3"
cockroach_organization = "YourCompany"  # For Enterprise license
cockroach_license = "crl-0-xxx..."      # Enterprise license key (enables encryption-at-rest)
cluster_profile_name = "m6a-2xlarge"
cockroach_disk_size_gb = 50
cockroach_disk_type = "gp3"
cockroach_disk_iops = null
cockroach_disk_throughput = null

proxy_defaults = {
    instance_architecture = "amd64"
    instance_type = "c6a.large"
}
ha_node_count = 2
pgb_port = 5432
db_port = 26257
ui_port = 8080
EOF
```

### Step 2: Run the controller

The controller handles everything: Terraform, certificates, cluster init, and PgBouncer configuration.

```bash
export TF_VAR_ssh_public_key=$(cat ./my-safe-directory/dev.pub)
python controller.py \
  --ssh-user debian \
  --ssh-key ./my-safe-directory/dev \
  --apply \
  --terraform-dir ./terraform/aws \
  --tfvars-file crdb-dcp-test.tfvars \
  --ca-cert \
  --node-certs \
  --root-cert new \
  --dns-zone dcp-test.crdb.com \
  --certs-dir ./certs/crdb-dcp-test \
  --ca-key ./my-safe-directory/ca.key \
  --start-nodes new \
  --sql-users \
  --auth-mode cert \
  --num-connections 32 \
  --database defaultdb \
  --pgb-port 5432 \
  --db-port 26257 \
  --ui-port 8080 \
  --pgb-client-user yourusername \
  --pgb-server-user pgb
```

### Step 3: Post-deployment configuration

After the controller completes, configure multi-region topology and create users:

```bash
# Configure multi-region database (for 3+ regions)
cockroach sql --certs-dir ./certs/crdb-dcp-test \
  --url "postgresql://db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full" -e """
ALTER DATABASE defaultdb SET PRIMARY REGION 'us-east-2';
ALTER DATABASE defaultdb SURVIVE ZONE FAILURE;
"""

# Create admin user for DB Console access
cockroach sql --certs-dir ./certs/crdb-dcp-test \
  --url "postgresql://db.us-east-2.dcp-test.crdb.com:26257/defaultdb?sslmode=verify-full" -e """
CREATE ROLE admin_user WITH LOGIN PASSWORD 'secret';
GRANT admin TO admin_user;
"""

# Test connection through distributed connection pool
cockroach sql --certs-dir ./certs/crdb-dcp-test \
  --url "postgresql://yourusername@pgb.us-east-2.dcp-test.crdb.com:5432/defaultdb?sslmode=verify-full" \
  -e "SHOW DATABASES;"
```

### Step 4: Monitor and operate

- **DB Console**: https://db.us-east-2.dcp-test.crdb.com:8080/
- **HAProxy Stats**: http://pgb.us-east-2.dcp-test.crdb.com:8404/stats
- **Connection endpoint for apps**: `postgresql://yourusername@pgb.us-east-2.dcp-test.crdb.com:5432/defaultdb?sslmode=verify-full`

### Step 5: Cleanup

When done testing:

```bash
terraform -chdir=terraform/aws destroy -var-file=crdb-dcp-test.tfvars -auto-approve
```

---

## Manual Deployment Workflow

If you prefer step-by-step control over each deployment phase, follow the manual Terraform workflow below.

This approach is documented in the following sections:
- [Cluster Initialization](#cluster-initialization) - Initialize the CockroachDB cluster
- [Encryption-at-Rest](#encryption-at-rest) - Configure Enterprise encryption
- [Scheduling Automated Backups](#scheduling-automated-backups) - Set up S3 backups
- [Monitoring with Prometheus and Grafana](#monitoring-with-prometheus-and-grafana) - Observability setup
- [Common Operations](#common-operations) - Day-to-day maintenance

**Prerequisites for manual workflow:**
1. Complete terraform apply successfully
2. Use the [Cluster Initialization](#cluster-initialization) script or manually configure nodes
3. Follow operational procedures in subsequent sections

---

## Managing Your Deployment

**Use controller.py to:**
- Modify PgBouncer pool configuration (increase `--num-connections`, change auth)
- Update HAProxy backends
- Regenerate certificates
- Apply infrastructure changes via Terraform

**Example: Update connection pool size**

```bash
python controller.py \
  --ssh-user debian \
  --ssh-key ./my-safe-directory/dev \
  --dns-zone dcp-test.crdb.com \
  --root-cert skip \
  --start-nodes skip \
  --skip-init \
  --skip-haproxy \
  --certs-dir ./certs/crdb-dcp-test \
  --ca-key ./my-safe-directory/ca.key \
  --auth-mode cert \
  --num-connections 96 \
  --database defaultdb \
  --pgb-port 5432 \
  --db-port 26257 \
  --pgb-client-user yourusername
```

**Example: Validate deployment without changes**

```bash
python controller.py \
  --root-cert skip \
  --start-nodes skip \
  --skip-init \
  --skip-pgbouncer \
  --skip-haproxy \
  --auth-mode cert \
  --dns-zone dcp-test.crdb.com \
  --certs-dir ./certs/crdb-dcp-test \
  --pgb-client-user yourusername \
  --database defaultdb \
  --pgb-port 5432 \
  --db-port 26257
```

**Use Terraform directly for infrastructure changes:**

```bash
terraform -chdir=terraform/aws init
terraform -chdir=terraform/aws plan -var-file=crdb-dcp-test.tfvars
terraform -chdir=terraform/aws apply -var-file=crdb-dcp-test.tfvars
terraform -chdir=terraform/aws output -json | jq -r '.'
```

---

## Architecture Details

This deployment uses a **defense-in-depth security model** with isolated network tiers:

```
Internet
    │
    ├─► DCP Nodes (Public Subnet)          ← Client entry point
    │   ├─ PgBouncer (connection pooling)  ← controller.py manages this via SSH
    │   ├─ HAProxy (load balancing)
    │   └─ Keepalived (VIP/EIP failover)
    │        │
    │        └──► CRDB Nodes (Private Subnet) ← Database tier (isolated)
    │              ├─ CockroachDB
    │              ├─ S3 access (IAM implicit auth)
    │              └─ NAT Gateway for outbound-only internet
    │
    └─► Bastion Hosts (Public Subnet)      ← Admin SSH access
             │
             └──► CRDB Nodes (Private Subnet) ← DB ops (SQL, logs, certs)
```

**Access paths:**
1. **Application clients** → DCP public IP/DNS → PgBouncer → CRDB (private)
2. **controller.py** → DCP nodes (SSH) → PgBouncer config management
3. **DB administrators** → Bastion (SSH) → CRDB nodes (SQL, logs, maintenance)
4. **CRDB backups** → S3 (IAM instance profile, no credentials required)

**Security guarantees:**
- CRDB nodes have **no public IPs** and **no inbound internet access**
- NAT Gateway provides **outbound-only internet** for package updates
- S3 access uses **IAM implicit auth** (`?AUTH=implicit` in connection strings)
- All EBS volumes **encrypted at rest** with customer-managed KMS keys
- Bastion required for **all CRDB node SSH access** (no direct access)

---

## SSH Access to Private CRDB Nodes

Since CRDB nodes are in private subnets with no public IPs, all SSH access must go through a bastion host. Use **ProxyCommand** (not ProxyJump `-J`) to specify the SSH key for both hops:

### Interactive SSH Session

```bash
# Set variables
BASTION_IP=<bastion-public-ip>
NODE_IP=<crdb-private-ip>
SSH_KEY=~/.ssh/<your-key>.pem

# Connect to CRDB node via bastion
ssh -i $SSH_KEY \
  -o ProxyCommand="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p debian@$BASTION_IP" \
  debian@$NODE_IP
```

### Run Remote Commands

```bash
# Execute a single command on CRDB node
ssh -i $SSH_KEY \
  -o ProxyCommand="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p debian@$BASTION_IP" \
  debian@$NODE_IP "sudo systemctl status cockroachdb"
```

### Copy Files (SCP)

```bash
# Copy files to CRDB node
scp -i $SSH_KEY \
  -o ProxyCommand="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p debian@$BASTION_IP" \
  local-file.txt debian@$NODE_IP:/tmp/

# Copy files from CRDB node
scp -i $SSH_KEY \
  -o ProxyCommand="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p debian@$BASTION_IP" \
  debian@$NODE_IP:/var/log/cockroach.log ./
```

### Why ProxyCommand instead of ProxyJump?

The `-J` (ProxyJump) flag doesn't allow specifying the SSH key for each hop independently. ProxyCommand gives full control over both SSH commands, ensuring your private key is used for both the bastion and the target node.

**This won't work:**
```bash
# ProxyJump doesn't work - can't specify key for proxy hop
ssh -i $SSH_KEY -J debian@$BASTION_IP debian@$NODE_IP
# Error: Permission denied (publickey)
```

---

## Cluster Initialization

After Terraform creates the infrastructure, CockroachDB nodes are **not yet initialized**. Use the provided automation script to:
1. Configure the `--join` flag on all nodes
2. Start the CockroachDB service
3. Initialize the cluster

### Automated Initialization (Recommended)

```bash
cd terraform/aws
./scripts/init-cockroach-cluster.sh
```

**What the script does:**
- Parses Terraform outputs to discover bastion and node IPs
- SSHs through the bastion to each private node
- Updates `/etc/systemd/system/cockroachdb.service` with the `--join` flag
- Starts `cockroachdb.service` on all nodes
- Runs `cockroach init` on the first node
- Displays cluster status

**Expected output:**
```
[INFO] Found 3 CockroachDB nodes
[INFO] Join string: 10.10.1.10:26257,10.20.1.10:26257,10.40.1.10:26257
[INFO] Step 1: Updating systemd service files with --join flag...
[INFO] Step 2: Starting CockroachDB service on all nodes...
[INFO] Step 3: Initializing cluster on 10.10.1.10...
[INFO] Step 4: Verifying cluster status...

  id |     address      |  build  |             started_at
-----+------------------+---------+-------------------------------------
   1 | 10.10.1.10:26257 | v25.4.3 | 2026-05-18 20:15:32.123456+00:00
   2 | 10.20.1.10:26257 | v25.4.3 | 2026-05-18 20:15:33.234567+00:00
   3 | 10.40.1.10:26257 | v25.4.3 | 2026-05-18 20:15:34.345678+00:00

✓ CockroachDB cluster initialized successfully!
```

### Manual Initialization (Alternative)

If you prefer to initialize manually:

```bash
# 1. Get node IPs from Terraform
terraform output -json > outputs.json
BASTION_IP=$(jq -r '.bastion_public_ips.value | to_entries[0].value' outputs.json)
NODE_IPS=$(jq -r '.crdb_private_ips.value | to_entries[] | .value[]' outputs.json | tr '\n' ',' | sed 's/,$//')
SSH_KEY=~/.ssh/<your-key>.pem

# 2. SSH to first node via bastion
ssh -i $SSH_KEY -o ProxyCommand="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p debian@$BASTION_IP" debian@$(echo $NODE_IPS | cut -d',' -f1)

# 3. On the node, edit the systemd service
sudo vi /etc/systemd/system/cockroachdb.service
# Add after --advertise-addr line:
#   --join=<node1-ip>:26257,<node2-ip>:26257,<node3-ip>:26257 \

# 4. Reload and start
sudo systemctl daemon-reload
sudo systemctl start cockroachdb

# 5. Repeat steps 2-4 for all nodes

# 6. On ONE node only, initialize the cluster
sudo -u cockroach cockroach init --certs-dir=/var/lib/cockroach/certs
```

---

## Encryption-at-Rest

The Terraform deployment configures **two layers of encryption** for defense-in-depth:

### Layer 1: EBS Volume Encryption (AWS KMS)

All EBS volumes (root and data) are encrypted at rest using AWS KMS with customer-managed keys:

- **Automatic**: Provisioned by Terraform with no manual configuration
- **Scope**: Encrypts the block device at the AWS storage layer
- **Key rotation**: KMS keys have automatic rotation enabled
- **Benefit**: Protects against physical disk theft and snapshot exposure

### Layer 2: CockroachDB Encryption-at-Rest (Database-Level)

CockroachDB encrypts data **inside the database** before writing to disk:

- **Automatic**: Configured in cloud-init with `--enterprise-encryption` flag
- **Scope**: Encrypts SST files, WAL logs, and all database files
- **Key**: 128-bit AES key generated per-node at `/var/lib/cockroach/keys/master.key`
- **Benefit**: Protects backups, exports, and data files even if EBS encryption is bypassed

**Enterprise License Configuration**

Database-level encryption requires a CockroachDB **Enterprise license**. 

**Option 1: Add to tfvars (Recommended - automatic activation)**

Add your license to `terraform.tfvars`:
```hcl
cockroach_organization = "YourCompany"
cockroach_license = "crl-0-xxxxxxxxxxxxxxxxxxxxx..."
```

The init script will automatically apply the license during cluster initialization, activating encryption-at-rest immediately.

**Option 2: Manual SQL activation**

If you didn't provide a license in tfvars:
```sql
-- Connect to any CRDB node
SET CLUSTER SETTING cluster.organization = 'YourCompany';
SET CLUSTER SETTING enterprise.license = 'crl-0-xxxxxxxxxxxxxxxxxxxxx...';
```

**Without a license:**
- The cluster will start successfully (encryption flag is ignored)
- Data is protected only by EBS encryption (Layer 1)
- Encryption-at-rest will activate immediately once license is applied

### Verifying Encryption Status

**Automated verification (during init script):**

If you provided a license in tfvars, the init script automatically verifies encryption is active as Step 5.

**Manual verification:**

```bash
# SSH to any CRDB node via bastion
BASTION_IP=$(terraform output -json | jq -r '.bastion_public_ips.value | to_entries[0].value')
NODE_IP=$(terraform output -json | jq -r '.crdb_private_ips.value | to_entries[0].value[0]')
SSH_KEY=~/.ssh/<your-key>.pem

ssh -i $SSH_KEY -o ProxyCommand="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p debian@$BASTION_IP" debian@$NODE_IP

# Check active encryption key
sudo -u cockroach cockroach debug encryption-active-key /mnt/cockroach-data

# Expected output (with Enterprise license applied):
#   /mnt/cockroach-data: aes-128-ctr (ID: master, created: 2026-05-21 12:34:56)

# If no license:
#   ERROR: encryption-at-rest requires enterprise license
```

**Verify via DB Console:**

1. Navigate to https://db.us-east-2.dcp-test.crdb.com:8080/
2. Go to **Metrics** → **Storage**
3. Look for "Encrypted Files" chart - should show all files encrypted

### Key Rotation

To rotate encryption keys (requires Enterprise license):

1. **Generate new key on all nodes:**
   ```bash
   # On each CRDB node
   sudo -u cockroach cockroach gen encryption-key -s 128 /var/lib/cockroach/keys/master-2.key
   ```

2. **Update systemd service file:**
   ```bash
   # Change --enterprise-encryption flag from:
   --enterprise-encryption=path=/mnt/cockroach-data,key=/var/lib/cockroach/keys/master.key,old-key=plain

   # To:
   --enterprise-encryption=path=/mnt/cockroach-data,key=/var/lib/cockroach/keys/master-2.key,old-key=/var/lib/cockroach/keys/master.key
   ```

3. **Restart CockroachDB (rolling restart to avoid downtime):**
   ```bash
   # Restart one node at a time
   sudo systemctl restart cockroachdb

   # Wait for node to rejoin cluster before proceeding to next node
   sudo -u cockroach cockroach node status --certs-dir=/var/lib/cockroach/certs
   ```

4. **Verify new key is active:**
   ```bash
   sudo -u cockroach cockroach debug encryption-active-key /mnt/cockroach-data
   # Should show: ID: master-2
   ```

For detailed key rotation procedures, see the [disk-level-encryption repository](https://github.com/roachlong/disk-level-encryption).

---

## Scheduling Automated Backups

CockroachDB supports native scheduled backups to S3. The Terraform configuration created three S3 buckets with IAM permissions already configured:

- `<project-name>-crdb-imports` — for `IMPORT INTO` operations
- `<project-name>-crdb-backups` — for automated backups (365-day retention)
- `<project-name>-crdb-audit-logs` — for audit logs (7-year retention, Glacier after 90 days)

### Connect to SQL Shell

```bash
# Get bastion and first node IP
BASTION_IP=$(terraform output -json | jq -r '.bastion_public_ips.value | to_entries[0].value')
FIRST_NODE=$(terraform output -json | jq -r '.crdb_private_ips.value | to_entries[0].value[0]')
SSH_KEY=~/.ssh/<your-key>.pem

# SSH to node via bastion
ssh -i $SSH_KEY -o ProxyCommand="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p debian@$BASTION_IP" debian@$FIRST_NODE

# Connect to SQL
sudo -u cockroach cockroach sql --certs-dir=/var/lib/cockroach/certs
```

### Create Daily Incremental + Weekly Full Backup Schedule

```sql
-- Daily incremental backups at 2:00 AM UTC, weekly full backup on Sunday
CREATE SCHEDULE crdb_daily_backup
  FOR BACKUP INTO 's3://<project-name>-crdb-backups/scheduled?AUTH=implicit'
  RECURRING '@daily'
  FULL BACKUP '@weekly'
  WITH SCHEDULE OPTIONS first_run = 'now';

-- Verify schedule created
SHOW SCHEDULES;
```

**Expected output:**
```
          id         |        label        | schedule_status |        next_run
---------------------+---------------------+-----------------+-------------------------
  123456789012345678 | crdb_daily_backup   | ACTIVE          | 2026-05-19 02:00:00+00
```

### Backup Schedule Options

**Option 1: Incremental every 6 hours + Daily full**
```sql
CREATE SCHEDULE crdb_frequent_backup
  FOR BACKUP INTO 's3://<project-name>-crdb-backups/frequent?AUTH=implicit'
  RECURRING '0 */6 * * *'  -- Every 6 hours
  FULL BACKUP '@daily'
  WITH SCHEDULE OPTIONS first_run = 'now';
```

**Option 2: Database-specific backup**
```sql
CREATE SCHEDULE compliance_db_backup
  FOR BACKUP DATABASE compliance INTO 's3://<project-name>-crdb-backups/compliance?AUTH=implicit'
  RECURRING '@daily'
  FULL BACKUP '@weekly'
  WITH SCHEDULE OPTIONS first_run = 'now';
```

**Option 3: Manual backup (for testing)**
```sql
BACKUP DATABASE defaultdb INTO 's3://<project-name>-crdb-backups/manual?AUTH=implicit';
```

### Verify Backups

```sql
-- Show all backups in the S3 bucket
SHOW BACKUPS IN 's3://<project-name>-crdb-backups/scheduled?AUTH=implicit';

-- Show details of a specific backup
SHOW BACKUP 's3://<project-name>-crdb-backups/scheduled/<timestamp>?AUTH=implicit';
```

### Restore from Backup

```sql
-- Restore entire cluster
RESTORE FROM LATEST IN 's3://<project-name>-crdb-backups/scheduled?AUTH=implicit';

-- Restore specific database
RESTORE DATABASE compliance FROM LATEST IN 's3://<project-name>-crdb-backups/compliance?AUTH=implicit';

-- Restore to a point in time
RESTORE FROM 's3://<project-name>-crdb-backups/scheduled/<timestamp>?AUTH=implicit'
  AS OF SYSTEM TIME '2026-05-18 10:00:00';
```

---

## Monitoring with Prometheus and Grafana

CockroachDB exposes a Prometheus-compatible metrics endpoint on port `:8080/_status/vars`. Since CRDB nodes are in private subnets, you'll need SSH tunnels to access them. DCP nodes (PgBouncer, HAProxy) are in public subnets and can be accessed directly.

### Architecture

```
┌─────────────────┐                                    ┌──────────────────────┐
│ Local Docker    │──── Direct HTTP ───────────────►  │ DCP Nodes (Public)   │
│ Prometheus      │     (no tunnel needed)             │ :8404/stats (HAProxy)│
│ + Grafana       │                                    │ :6432 (PgBouncer)    │
└─────────────────┘                                    └──────────────────────┘
        │
        │           SSH Tunnel                ┌──────────────────┐
        └──────────────────────────────────►  │  AWS Bastion     │
                  localhost:8080              │  (Jump Host)     │
                                              └──────────────────┘
                                                       │ Private VPC
                                          ┌────────────▼─────────────┐
                                          │ CRDB Nodes (Private IPs) │
                                          │ :8080/_status/vars       │
                                          └──────────────────────────┘
```

**What you can access directly** (DCP nodes are public):
- HAProxy stats: `http://<dcp-public-ip>:8404/stats`
- PgBouncer admin console: `psql "host=<dcp-public-ip> port=6432 dbname=pgbouncer"`

**What needs SSH tunnel** (CRDB nodes are private):
- CockroachDB metrics: `:8080/_status/vars`
- CockroachDB Admin UI: `:8080` (web interface)

### Option 1: SSH Tunnel (Simplest for Local Development)

**Step 1: Create SSH tunnels to CRDB nodes**

```bash
# Get bastion IP and CRDB node IPs
BASTION_IP=$(terraform output -json | jq -r '.bastion_public_ips.value | to_entries[0].value')
NODE1=$(terraform output -json | jq -r '.crdb_private_ips.value | to_entries[0].value[0]')
NODE2=$(terraform output -json | jq -r '.crdb_private_ips.value | to_entries[1].value[0]')
NODE3=$(terraform output -json | jq -r '.crdb_private_ips.value | to_entries[2].value[0]')
SSH_KEY=~/.ssh/<your-key>.pem

# Create SSH tunnels (run in separate terminals or use nohup)
ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ProxyCommand="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p debian@$BASTION_IP" \
  -L 8081:$NODE1:8080 debian@$NODE1 -N &

ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ProxyCommand="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p debian@$BASTION_IP" \
  -L 8082:$NODE2:8080 debian@$NODE2 -N &

ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ProxyCommand="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p debian@$BASTION_IP" \
  -L 8083:$NODE3:8080 debian@$NODE3 -N &

# Verify tunnels are working
curl http://localhost:8081/_status/vars | head -20
curl http://localhost:8082/_status/vars | head -20
curl http://localhost:8083/_status/vars | head -20
```

**Step 2: Configure Prometheus**

Create or update `prometheus.yml` on your local Docker Prometheus instance:

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  # CockroachDB nodes via SSH tunnels
  - job_name: 'cockroachdb'
    metrics_path: '/_status/vars'
    static_configs:
      - targets:
          - 'host.docker.internal:8081'  # macOS Docker
          - 'host.docker.internal:8082'
          - 'host.docker.internal:8083'
        labels:
          cluster: 'crdb-dcp-test'
          region: 'multi-region'

  # For Linux Docker, use:
  # - targets:
  #     - '172.17.0.1:8081'  # Docker bridge gateway
  #     - '172.17.0.1:8082'
  #     - '172.17.0.1:8083'
```

**Step 3: Reload Prometheus**

```bash
# If using Docker Compose
docker-compose restart prometheus

# Or send SIGHUP to reload config
docker kill -s HUP <prometheus-container-id>

# Verify targets are UP in Prometheus UI
open http://localhost:9090/targets
```

**Step 4: Import CockroachDB Grafana Dashboards**

1. Download official CRDB dashboards:
   ```bash
   curl -O https://raw.githubusercontent.com/cockroachdb/cockroach/master/monitoring/grafana-dashboards/runtime.json
   curl -O https://raw.githubusercontent.com/cockroachdb/cockroach/master/monitoring/grafana-dashboards/storage.json
   curl -O https://raw.githubusercontent.com/cockroachdb/cockroach/master/monitoring/grafana-dashboards/sql.json
   ```

2. In Grafana UI (`http://localhost:3000`):
   - Go to **Dashboards** → **Import**
   - Upload each `.json` file
   - Select your Prometheus data source
   - Click **Import**

3. View key metrics:
   - **Runtime Dashboard**: CPU, memory, goroutines, GC stats
   - **Storage Dashboard**: Disk IOPS, read/write latency, LSM compactions
   - **SQL Dashboard**: Query latency (p50, p99), transaction rates, connection counts

### Option 2: VPN / Direct Connect (Production)

For production environments, use VPN or AWS Direct Connect instead of SSH tunnels:

1. **AWS Client VPN** or **Site-to-Site VPN** connects your office/network to the AWS VPC
2. Update Prometheus `scrape_configs` to use private IPs directly:
   ```yaml
   - targets:
       - '10.10.1.10:8080'  # us-east-1 node
       - '10.20.1.10:8080'  # us-east-2 node
       - '10.40.1.10:8080'  # us-west-2 node
   ```

3. Ensure VPC security groups allow Prometheus ingress on port 8080 from your VPN CIDR

### Key Metrics to Monitor

**Clock Offset (Critical for CRDB)**
```promql
# Alert if clock offset exceeds 400ms (80% of --max-offset=500ms)
clock_offset_meannanos / 1000000 > 400
```

**Under-Replicated Ranges (Data Loss Risk)**
```promql
# Alert if any ranges are under-replicated for > 5 minutes
ranges_underreplicated > 0
```

**Disk Space Usage**
```promql
# Alert if disk usage exceeds 80%
(capacity - available) / capacity > 0.8
```

**Connection Pool Saturation (via PgBouncer stats)**
```promql
# Monitor on DCP nodes
pgbouncer_pools_cl_waiting > 10  # Clients waiting for connections
```

**Query Latency P99**
```promql
histogram_quantile(0.99, rate(sql_exec_latency_bucket[5m]))
```

---

## Multi-Region Configuration (Optional)

If you deployed **3 or more regions** and want to use CockroachDB's multi-region SQL abstractions (region-aware replica placement, `REGIONAL BY ROW` tables, etc.), configure the cluster topology:

```sql
-- Connect to SQL shell
sudo -u cockroach cockroach sql --certs-dir=/var/lib/cockroach/certs

-- Set primary region
ALTER DATABASE defaultdb PRIMARY REGION 'us-east-1';

-- Add secondary regions
ALTER DATABASE defaultdb ADD REGION 'us-east-2';
ALTER DATABASE defaultdb ADD REGION 'us-west-2';

-- Verify configuration
SHOW REGIONS FROM DATABASE defaultdb;
```

**Expected output:**
```
  database  |  region    | primary
------------+------------+---------
  defaultdb | us-east-1  |  true
  defaultdb | us-east-2  |  false
  defaultdb | us-west-2  |  false
```

### Region-Aware Table Placement

Once regions are configured, you can control replica placement per table:

```sql
-- REGIONAL BY TABLE: All replicas in one region (lowest latency for region-specific data)
CREATE TABLE users (
  id UUID PRIMARY KEY,
  name STRING
) LOCALITY REGIONAL BY TABLE IN 'us-east-1';

-- REGIONAL BY ROW: Row-level replica placement (global data with regional affinity)
CREATE TABLE transactions (
  id UUID PRIMARY KEY,
  user_region STRING AS (crdb_region) STORED,
  amount DECIMAL,
  crdb_region crdb_internal_region NOT NULL DEFAULT gateway_region()::crdb_internal_region
) LOCALITY REGIONAL BY ROW;

-- GLOBAL: Replicas in all regions (read-optimized for global data)
CREATE TABLE exchange_rates (
  currency STRING PRIMARY KEY,
  rate DECIMAL
) LOCALITY GLOBAL;
```

**When NOT to use multi-region abstractions:**
- Only 2 regions deployed (multi-region SQL requires ≥3 regions for quorum)
- Performance testing / benchmarking (adds complexity)
- You want manual control over replica placement via zone configs

---

## Common Operations

### Accessing the SQL Shell

```bash
# Via bastion jump host
BASTION_IP=$(terraform output -json | jq -r '.bastion_public_ips.value | to_entries[0].value')
NODE_IP=$(terraform output -json | jq -r '.crdb_private_ips.value | to_entries[0].value[0]')
SSH_KEY=~/.ssh/<your-key>.pem

ssh -i $SSH_KEY -o ProxyCommand="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p debian@$BASTION_IP" debian@$NODE_IP

# Once connected to the node
sudo -u cockroach cockroach sql --certs-dir=/var/lib/cockroach/certs
```

### Viewing Logs

```bash
# CockroachDB service logs
journalctl -u cockroachdb -f

# CRDB structured logs
tail -f /var/lib/cockroach/logs/cockroach.log
```

### Checking Clock Sync

```bash
# Chrony sync status
chronyc tracking

# Expected output shows offset < 10ms
#   Stratum         : 4
#   Reference time  : Mon May 18 20:00:00 2026
#   System time     : 0.000002345 seconds fast of NTP time
#   Last offset     : +0.000001234 seconds
#   RMS offset      : 0.000002456 seconds
```

### Cluster Health Check

```sql
-- Show node status
SELECT node_id, address, build, started_at, is_live
FROM crdb_internal.gossip_nodes
ORDER BY node_id;

-- Show under-replicated ranges (should be 0)
SELECT range_id, start_key, end_key, replicas, learner_replicas
FROM crdb_internal.ranges_no_leases
WHERE array_length(replicas, 1) < 3;

-- Show slow queries (p99 latency)
SHOW CLUSTER SETTING sql.stats.response_time_percentile.p99;
```

### Decommissioning a Node

```bash
# Get node details
BASTION_IP=$(terraform output -json | jq -r '.bastion_public_ips.value | to_entries[0].value')
NODE_IP=<node-to-decommission-ip>
SSH_KEY=~/.ssh/<your-key>.pem

# SSH to the node to decommission
ssh -i $SSH_KEY -o ProxyCommand="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p debian@$BASTION_IP" debian@$NODE_IP

# Decommission (drains replicas, then stops)
sudo -u cockroach cockroach node decommission <node-id> --certs-dir=/var/lib/cockroach/certs --host=localhost:26257

# Monitor decommission status
sudo -u cockroach cockroach node status --decommission --certs-dir=/var/lib/cockroach/certs
```

---

## Security Notes

### Bastion Access

- Bastion hosts are the **only** public entry point to CRDB nodes in private subnets
- SSH key required for bastion access
- Private CRDB nodes are **not** directly reachable from the internet
- To add/remove allowed IPs, update `ssh_ip_range` in `terraform.tfvars` and re-apply
- See [SSH Access to Private CRDB Nodes](#ssh-access-to-private-crdb-nodes) for connection examples

### S3 Bucket Access

- IAM instance profiles grant CRDB nodes access to S3 (no credentials in connection strings)
- Use `AUTH=implicit` in all S3 URIs: `s3://bucket/path?AUTH=implicit`
- S3 buckets have public access blocked and server-side encryption enabled

### Certificate Management

CockroachDB requires TLS certificates for node-to-node and client-to-node communication. The current cloud-init creates the `/var/lib/cockroach/certs` directory but **does not generate certificates**. You must:

1. Generate a CA certificate
2. Generate node certificates for each node
3. Distribute certificates to all nodes before starting CockroachDB

**Automated certificate generation will be added in a future update.**

For development/testing, you can use `cockroach cert`:

```bash
# On your local machine
mkdir certs my-safe-directory
cockroach cert create-ca --certs-dir=certs --ca-key=my-safe-directory/ca.key
cockroach cert create-node <node1-ip> <node2-ip> <node3-ip> localhost 127.0.0.1 --certs-dir=certs --ca-key=my-safe-directory/ca.key
cockroach cert create-client root --certs-dir=certs --ca-key=my-safe-directory/ca.key

# Copy certs to all nodes
SSH_KEY=~/.ssh/<your-key>.pem
for NODE in $NODE1 $NODE2 $NODE3; do
  scp -i $SSH_KEY -o ProxyCommand="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p debian@$BASTION_IP" -r certs/* debian@$NODE:/tmp/
  ssh -i $SSH_KEY -o ProxyCommand="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p debian@$BASTION_IP" debian@$NODE "sudo mv /tmp/*.crt /tmp/*.key /var/lib/cockroach/certs/ && sudo chown cockroach:cockroach /var/lib/cockroach/certs/*"
done
```

---

## Troubleshooting

### Cluster won't initialize

```bash
# Check if CockroachDB is running
sudo systemctl status cockroachdb

# View logs
journalctl -u cockroachdb -n 100

# Common issues:
# - Clock offset > 500ms (check chronyc tracking)
# - Certificates missing/invalid (check /var/lib/cockroach/certs)
# - --join flag incorrect (check systemd service file)
```

### Prometheus can't scrape metrics

```bash
# Verify SSH tunnel is active
ps aux | grep "ssh -L 808"

# Test metrics endpoint directly
curl http://localhost:8081/_status/vars

# Check Prometheus targets page
# http://localhost:9090/targets
# Status should show "UP" (green)
```

### S3 backup fails

```sql
-- Check IAM permissions
BACKUP DATABASE defaultdb INTO 's3://<bucket>/test?AUTH=implicit';

-- Common errors:
-- "AccessDenied" → IAM policy missing or incorrect
-- "NoSuchBucket" → Bucket name typo or wrong region
-- "InvalidBucketName" → Bucket name must be globally unique
```

---

## Next Steps

- [ ] Configure TLS certificates for production use
- [ ] Set up CloudWatch/Datadog alerts for clock offset, disk usage, under-replicated ranges
- [ ] Test backup/restore procedures
- [ ] Load test the cluster and tune `--cache` / `--max-sql-memory` flags
- [ ] Review CockroachDB production checklist: https://www.cockroachlabs.com/docs/stable/recommended-production-settings

For questions or issues, refer to:
- CockroachDB docs: https://www.cockroachlabs.com/docs/
- Community forum: https://forum.cockroachlabs.com/
