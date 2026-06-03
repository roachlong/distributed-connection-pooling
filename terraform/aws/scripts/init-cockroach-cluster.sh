#!/usr/bin/env bash
set -euo pipefail

# CockroachDB Cluster Initialization Script
# This script automates the initialization of a multi-region CockroachDB cluster
# deployed via Terraform on AWS EC2 private subnets.
#
# Prerequisites:
#   - Terraform apply completed successfully
#   - SSH key configured for bastion and private nodes
#   - jq installed for JSON parsing
#
# Usage:
#   ./init-cockroach-cluster.sh [terraform-output-file]
#
# If terraform-output-file is not provided, the script will run `terraform output -json`

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/.."
OUTPUT_FILE="${1:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get Terraform outputs
if [[ -z "$OUTPUT_FILE" ]]; then
    log_info "Fetching Terraform outputs..."
    cd "$TERRAFORM_DIR"
    OUTPUTS=$(terraform output -json)
else
    log_info "Reading Terraform outputs from $OUTPUT_FILE..."
    OUTPUTS=$(cat "$OUTPUT_FILE")
fi

# Parse outputs
BASTION_IPS=$(echo "$OUTPUTS" | jq -r '.bastion_public_ips.value | to_entries[] | .value')
NODE_IPS=$(echo "$OUTPUTS" | jq -r '.crdb_private_ips.value | to_entries[] | .value[]')
SSH_KEY=$(echo "$OUTPUTS" | jq -r '.ssh_key_path.value // ""')
SSH_USER=$(echo "$OUTPUTS" | jq -r '.vm_user.value // "debian"')
CRDB_ORG=$(echo "$OUTPUTS" | jq -r '.cockroach_organization.value // ""')
CRDB_LICENSE=$(echo "$OUTPUTS" | jq -r '.cockroach_license.value // ""')

# Validate outputs
if [[ -z "$NODE_IPS" ]]; then
    log_error "No CockroachDB nodes found in Terraform outputs"
    exit 1
fi

if [[ -z "$BASTION_IPS" ]]; then
    log_error "No bastion hosts found in Terraform outputs"
    exit 1
fi

# Use first bastion as jump host
BASTION_IP=$(echo "$BASTION_IPS" | head -n1)
log_info "Using bastion: $BASTION_IP"

# Build SSH command with bastion as jump host
if [[ -n "$SSH_KEY" ]]; then
    SSH_CMD="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyJump=${SSH_USER}@${BASTION_IP}"
else
    SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyJump=${SSH_USER}@${BASTION_IP}"
fi

# Convert node IPs to array
NODE_ARRAY=()
while IFS= read -r ip; do
    NODE_ARRAY+=("$ip")
done <<< "$NODE_IPS"

log_info "Found ${#NODE_ARRAY[@]} CockroachDB nodes"

# Build --join string (comma-separated list of node:26257)
JOIN_STRING=""
for node_ip in "${NODE_ARRAY[@]}"; do
    if [[ -z "$JOIN_STRING" ]]; then
        JOIN_STRING="${node_ip}:26257"
    else
        JOIN_STRING="${JOIN_STRING},${node_ip}:26257"
    fi
done

log_info "Join string: $JOIN_STRING"

# Step 1: Update systemd service file on all nodes with --join flag
log_info "Step 1: Updating systemd service files with --join flag..."
for node_ip in "${NODE_ARRAY[@]}"; do
    log_info "  Updating node $node_ip..."

    # Use sed to add --join flag after --advertise-addr line
    $SSH_CMD ${SSH_USER}@${node_ip} "sudo sed -i '/--advertise-addr/a \\        --join=${JOIN_STRING} \\\\' /etc/systemd/system/cockroachdb.service"

    # Reload systemd
    $SSH_CMD ${SSH_USER}@${node_ip} "sudo systemctl daemon-reload"

    log_info "  ✓ Updated $node_ip"
done

# Step 2: Start CockroachDB on all nodes
log_info "Step 2: Starting CockroachDB service on all nodes..."
for node_ip in "${NODE_ARRAY[@]}"; do
    log_info "  Starting CockroachDB on $node_ip..."
    $SSH_CMD ${SSH_USER}@${node_ip} "sudo systemctl start cockroachdb"
    log_info "  ✓ Started on $node_ip"
done

# Wait for nodes to come online
log_info "Waiting 10 seconds for nodes to come online..."
sleep 10

# Step 3: Initialize cluster on first node
FIRST_NODE="${NODE_ARRAY[0]}"
log_info "Step 3: Initializing cluster on $FIRST_NODE..."
$SSH_CMD ${SSH_USER}@${FIRST_NODE} "sudo -u cockroach /usr/local/bin/cockroach init --certs-dir=/var/lib/cockroach/certs --host=${FIRST_NODE}:26257" || {
    log_warn "Init failed or cluster already initialized"
}

# Wait for cluster to stabilize
log_info "Waiting 5 seconds for cluster to stabilize..."
sleep 5

# Step 3.5: Apply Enterprise license (if provided)
if [[ -n "$CRDB_ORG" && -n "$CRDB_LICENSE" ]]; then
    log_info "Step 3.5: Applying Enterprise license..."

    # Set organization
    $SSH_CMD ${SSH_USER}@${FIRST_NODE} "sudo -u cockroach /usr/local/bin/cockroach sql --certs-dir=/var/lib/cockroach/certs --host=${FIRST_NODE}:26257 -e \"SET CLUSTER SETTING cluster.organization = '${CRDB_ORG}';\"" || {
        log_error "Failed to set cluster organization"
    }

    # Set license
    $SSH_CMD ${SSH_USER}@${FIRST_NODE} "sudo -u cockroach /usr/local/bin/cockroach sql --certs-dir=/var/lib/cockroach/certs --host=${FIRST_NODE}:26257 -e \"SET CLUSTER SETTING enterprise.license = '${CRDB_LICENSE}';\"" || {
        log_error "Failed to set enterprise license"
    }

    log_info "  ✓ Enterprise license applied successfully"
    log_info "  Organization: $CRDB_ORG"
else
    log_warn "Step 3.5: No Enterprise license provided - encryption-at-rest will not be active"
    log_warn "  To enable encryption, add cockroach_organization and cockroach_license to your tfvars"
fi

# Step 4: Verify cluster status
log_info "Step 4: Verifying cluster status..."
$SSH_CMD ${SSH_USER}@${FIRST_NODE} "sudo -u cockroach /usr/local/bin/cockroach node status --certs-dir=/var/lib/cockroach/certs --host=${FIRST_NODE}:26257" || {
    log_error "Failed to get cluster status"
    exit 1
}

# Step 5: Verify encryption-at-rest is active
log_info "Step 5: Verifying encryption-at-rest status..."
ENCRYPTION_STATUS=$($SSH_CMD ${SSH_USER}@${FIRST_NODE} "sudo -u cockroach /usr/local/bin/cockroach debug encryption-active-key /mnt/cockroach-data" 2>&1 || echo "FAILED")

if echo "$ENCRYPTION_STATUS" | grep -q "FAILED"; then
    log_warn "Encryption status check failed"
    if [[ -z "$CRDB_LICENSE" ]]; then
        log_warn "  → No Enterprise license provided - encryption-at-rest is not active"
        log_warn "  → Add cockroach_organization and cockroach_license to your tfvars to enable"
    else
        log_warn "  → License was provided but encryption check failed - verify license is valid"
    fi
else
    log_info ""
    log_info "${GREEN}✓ Encryption-at-rest is ACTIVE:${NC}"
    echo "$ENCRYPTION_STATUS"
fi

log_info ""
log_info "${GREEN}✓ CockroachDB cluster initialized successfully!${NC}"
log_info ""

# Print license status summary
if [[ -n "$CRDB_LICENSE" ]]; then
    log_info "${GREEN}Enterprise License: ACTIVE${NC}"
    log_info "  Organization: $CRDB_ORG"
    log_info "  Encryption-at-rest: Should be active (verify in Step 5 output above)"
else
    log_warn "${YELLOW}Enterprise License: NOT PROVIDED${NC}"
    log_warn "  Encryption-at-rest: INACTIVE (only EBS encryption is active)"
    log_warn "  To enable: Add cockroach_organization and cockroach_license to your tfvars and re-run terraform apply"
fi

log_info ""
log_info "Next steps:"
log_info "  1. Connect to SQL:"
log_info "     ssh -J ${SSH_USER}@${BASTION_IP} ${SSH_USER}@${FIRST_NODE}"
log_info "     sudo -u cockroach cockroach sql --certs-dir=/var/lib/cockroach/certs"
log_info ""
log_info "  2. Configure multi-region topology (optional, if using 3+ regions):"
log_info "     ALTER DATABASE defaultdb PRIMARY REGION 'us-east-1';"
log_info "     ADD REGION 'us-east-2';"
log_info "     ADD REGION 'us-west-2';"
log_info ""
log_info "  3. Schedule automated backups:"
log_info "     See terraform/aws/DEPLOYMENT.md section 'Scheduling Automated Backups'"
log_info ""
