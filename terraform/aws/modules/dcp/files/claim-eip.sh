#!/usr/bin/env bash
set -euo pipefail

ALLOC_ID="${1:-}"

if [[ -z "$ALLOC_ID" ]]; then
  echo "ERROR: allocation-id not provided to claim-eip.sh" >&2
  exit 1
fi

# Fetch IMDSv2 token once
TOKEN=$(curl -sS -X PUT \
  "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# Determine region
REGION="${AWS_REGION:-}"
if [[ -z "$REGION" ]]; then
  AZ=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/placement/availability-zone)
  REGION="${AZ::-1}"
fi

# Instance ID
INSTANCE_ID=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

echo "Claiming EIP $ALLOC_ID for instance $INSTANCE_ID in region $REGION"

aws --region "$REGION" ec2 associate-address \
  --allocation-id "$ALLOC_ID" \
  --instance-id "$INSTANCE_ID" \
  --allow-reassociation
