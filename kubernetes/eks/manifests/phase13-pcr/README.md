# Phase 13: Physical Cluster Replication (PCR)

**Status**: Not yet implemented

## Objective

Deploy secondary region (us-west-2) EKS cluster and configure active-passive PCR from East to West.

## Implementation Notes

When building Phase 13 setup script, apply the same auto-update logic for `KMS_KEY_ARN_WEST` as Phase 1 does for `KMS_KEY_ARN_EAST`:

```bash
# Auto-update config.env if:
# 1. We created a new key (not reusing existing)
# 2. Original value in config.env was blank/empty
if [[ "$key_created" == true ]] && [[ -z "$original_key_arn_west" ]]; then
    sed -i '' "s|export KMS_KEY_ARN_WEST=\"\"|export KMS_KEY_ARN_WEST=\"${KMS_KEY_ARN_WEST}\"|" ../../config.env
fi
```

## Dependencies

- Phase 1-12 completed in East region (including NiFi Phase 8, Enterprise Phase 9)
- Transit Gateway or VPC peering configured between regions
- Same configuration pattern as Phase 1 but for WEST region variables

## TODO

- [ ] Create setup.sh for West region deployment (mirror Phase 1)
- [ ] Implement KMS key auto-update for WEST
- [ ] Create S3 buckets in West region
- [ ] Deploy EKS cluster in us-west-2
- [ ] Configure Transit Gateway peering
- [ ] Enable rangefeed on both clusters
- [ ] Create PCR replication configuration
- [ ] Test failover and failback procedures
