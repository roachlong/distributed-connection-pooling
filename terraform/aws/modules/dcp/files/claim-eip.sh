#!/usr/bin/env bash
set -euo pipefail

ALLOC_ID="$1"
REGION="${AWS_REGION:-}"

if [[ -z "$REGION" ]]; then
  # fallback: parse from metadata AZ
  TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
  AZ=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
  REGION="${AZ::-1}"
fi

TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

aws --region "$REGION" ec2 associate-address \
  --allocation-id "$ALLOC_ID" \
  --instance-id "$INSTANCE_ID" \
  --allow-reassociation
