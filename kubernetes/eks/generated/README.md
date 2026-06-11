# Generated Files Directory

This directory contains **generated files** created during deployment. These files are **automatically excluded from git** via `.gitignore`.

## Why This Directory Exists

Generated files often contain sensitive information:
- **KMS Key ARNs** (customer-managed encryption keys)
- **Vault Unseal Keys** (critical secrets)
- **Vault Root Tokens** (administrative credentials)
- **Environment-specific values** (AWS account IDs, regions, etc.)

## Directory Structure

```
generated/
├── phase1/
│   ├── cluster-east.yaml         # Generated from cluster-east.yaml template
│   └── storageclass.yaml         # Generated from storageclass.yaml.template (contains KMS ARN)
├── phase2/
│   ├── vault-issuer.yaml         # Generated from vault-issuer.yaml.template
│   └── vault-keys.json           # Vault unseal keys and root token (CRITICAL!)
├── phase4/
│   ├── node-certificate.yaml     # Generated from node-certificate.yaml.template
│   ├── client-certificate.yaml   # Generated from client-certificate.yaml.template
│   └── crdb-cluster.yaml         # Generated from crdb-cluster.yaml.template
└── phase5/
    ├── pgbouncer-configmap.yaml  # Generated from pgbouncer-configmap.yaml.template
    ├── pgbouncer-deployment.yaml # Generated from pgbouncer-deployment.yaml.template
    └── pgbouncer-service.yaml    # Generated from pgbouncer-service.yaml.template
```

## How Files Are Generated

Setup scripts automatically generate these files:

**Phase 1:**
```bash
envsubst < cluster-east.yaml > generated/phase1/cluster-east.yaml
envsubst < storageclass.yaml.template > generated/phase1/storageclass.yaml
```

**Phase 2:**
```bash
vault operator init > generated/phase2/vault-keys.json
envsubst < vault-issuer.yaml.template > generated/phase2/vault-issuer.yaml
```

**Phase 4:**
```bash
envsubst < node-certificate.yaml.template > generated/phase4/node-certificate.yaml
envsubst < client-certificate.yaml.template > generated/phase4/client-certificate.yaml
envsubst < crdb-cluster.yaml.template > generated/phase4/crdb-cluster.yaml
```

**Phase 5:**
```bash
envsubst < pgbouncer-configmap.yaml.template > generated/phase5/pgbouncer-configmap.yaml
envsubst < pgbouncer-deployment.yaml.template > generated/phase5/pgbouncer-deployment.yaml
envsubst < pgbouncer-service.yaml.template > generated/phase5/pgbouncer-service.yaml
```

## Security Best Practices

### For vault-keys.json
⚠️ **CRITICAL**: This file contains Vault unseal keys and root token!

**Production environments should:**
1. Store unseal keys in AWS Secrets Manager or HSM
2. Split keys among multiple trusted administrators (Shamir's Secret Sharing)
3. Never commit to version control
4. Rotate root token after initial setup

**Development/Testing:**
- File is stored locally in `generated/phase2/`
- Automatically excluded from git
- Deleted during teardown (unless you back it up)

### For Files with KMS ARNs
- KMS keys are customer-managed and account-specific
- ARNs should not be shared across environments
- Templates use `${KMS_KEY_ARN_EAST}` placeholder
- Generated files contain actual ARNs

## What to Commit

✅ **Commit:**
- `*.template` files (with `${VARIABLE}` placeholders)
- `cluster-east.yaml` (template with variables)
- README and documentation files

❌ **Never Commit:**
- Files in `generated/` directory
- `vault-keys.json`
- Any file with actual KMS ARNs, tokens, or secrets

## Cleanup

The `generated/` directory is automatically cleaned during teardown:

```bash
# Teardown removes generated files
./teardown.sh --phase 1

# Manual cleanup
rm -rf generated/
```

After cleanup, the setup scripts will regenerate files on next deployment.
