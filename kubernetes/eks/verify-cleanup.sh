#!/bin/bash
set -e

#######################################
# Verify Complete Cleanup
#######################################
# Checks for any remaining project resources

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_header() {
    echo -e "\n${GREEN}===================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${GREEN}===================================${NC}\n"
}

print_info() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

# Load config
source "$CONFIG_FILE"

FOUND_RESOURCES=0
IN_PROGRESS_RESOURCES=0

print_header "Verifying Complete Cleanup for Project: ${PROJECT_NAME}"

#######################################
# 1. EKS Clusters
#######################################
print_header "1. Checking EKS Clusters"

CLUSTERS=$(eksctl get cluster --region "${AWS_REGION_EAST}" --profile "${AWS_PROFILE}" -o json 2>/dev/null | jq -r '.[].Name' | grep "${PROJECT_NAME}" || echo "")

if [[ -z "$CLUSTERS" ]]; then
    print_info "No EKS clusters found"
else
    # Check if cluster is deleting
    CLUSTER_STATUS=$(aws eks describe-cluster --name "${CLUSTERS}" --region "${AWS_REGION_EAST}" --profile "${AWS_PROFILE}" --query 'cluster.status' --output text 2>/dev/null || echo "")
    if [[ "$CLUSTER_STATUS" == "DELETING" ]]; then
        print_warning "EKS cluster is deleting (in progress):"
        echo "$CLUSTERS - Status: DELETING"
        IN_PROGRESS_RESOURCES=$((IN_PROGRESS_RESOURCES + 1))
    else
        print_error "Found EKS clusters:"
        echo "$CLUSTERS - Status: $CLUSTER_STATUS"
        FOUND_RESOURCES=$((FOUND_RESOURCES + 1))
    fi
fi

#######################################
# 2. CloudFormation Stacks
#######################################
print_header "2. Checking CloudFormation Stacks"

# Get all stacks with details
STACK_DETAILS=$(aws cloudformation list-stacks \
    --region "${AWS_REGION_EAST}" \
    --profile "${AWS_PROFILE}" \
    --query "StackSummaries[?contains(StackName, '${PROJECT_NAME}') && StackStatus!='DELETE_COMPLETE'].{Name:StackName,Status:StackStatus}" \
    --output json)

if [[ "$STACK_DETAILS" == "[]" ]] || [[ -z "$STACK_DETAILS" ]]; then
    print_info "No CloudFormation stacks found"
else
    # Separate stacks by status
    IN_PROGRESS_STACKS=$(echo "$STACK_DETAILS" | jq -r '.[] | select(.Status=="DELETE_IN_PROGRESS") | "\(.Name) - \(.Status)"')
    FAILED_STACKS=$(echo "$STACK_DETAILS" | jq -r '.[] | select(.Status=="DELETE_FAILED") | "\(.Name) - \(.Status)"')
    OTHER_STACKS=$(echo "$STACK_DETAILS" | jq -r '.[] | select(.Status!="DELETE_IN_PROGRESS" and .Status!="DELETE_FAILED") | "\(.Name) - \(.Status)"')

    if [[ -n "$IN_PROGRESS_STACKS" ]]; then
        print_warning "CloudFormation stacks deleting (in progress):"
        echo "$IN_PROGRESS_STACKS"
        IN_PROGRESS_RESOURCES=$((IN_PROGRESS_RESOURCES + 1))
    fi

    if [[ -n "$FAILED_STACKS" ]]; then
        print_error "CloudFormation stacks in DELETE_FAILED state:"
        echo "$FAILED_STACKS"
        FOUND_RESOURCES=$((FOUND_RESOURCES + 1))
    fi

    if [[ -n "$OTHER_STACKS" ]]; then
        print_error "CloudFormation stacks still active:"
        echo "$OTHER_STACKS"
        FOUND_RESOURCES=$((FOUND_RESOURCES + 1))
    fi
fi

#######################################
# 3. S3 Buckets
#######################################
print_header "3. Checking S3 Buckets"

BUCKETS=$(aws s3 ls --profile "${AWS_PROFILE}" 2>/dev/null | grep "${PROJECT_NAME}" | awk '{print $3}' || echo "")

if [[ -z "$BUCKETS" ]]; then
    print_info "No S3 buckets found"
else
    print_error "Found S3 buckets:"
    echo "$BUCKETS"
    FOUND_RESOURCES=$((FOUND_RESOURCES + 1))
fi

#######################################
# 4. KMS Keys
#######################################
print_header "4. Checking KMS Keys"

KMS_ALIASES=$(aws kms list-aliases \
    --region "${AWS_REGION_EAST}" \
    --profile "${AWS_PROFILE}" \
    --query "Aliases[?contains(AliasName, 'crdb-ebs')].{Alias:AliasName,KeyId:TargetKeyId}" \
    --output table)

if echo "$KMS_ALIASES" | grep -q "crdb-ebs"; then
    print_warning "Found KMS keys (may be PendingDeletion):"
    echo "$KMS_ALIASES"

    # Check key state
    for key_id in $(echo "$KMS_ALIASES" | grep "crdb-ebs" | awk '{print $4}'); do
        KEY_STATE=$(aws kms describe-key \
            --key-id "$key_id" \
            --region "${AWS_REGION_EAST}" \
            --profile "${AWS_PROFILE}" \
            --query 'KeyMetadata.KeyState' \
            --output text)
        echo "  Key ${key_id}: ${KEY_STATE}"

        if [[ "$KEY_STATE" != "PendingDeletion" ]]; then
            FOUND_RESOURCES=$((FOUND_RESOURCES + 1))
        fi
    done
else
    print_info "No KMS keys found"
fi

#######################################
# 5. IAM Policies
#######################################
print_header "5. Checking IAM Policies"

IAM_POLICIES=$(aws iam list-policies \
    --scope Local \
    --profile "${AWS_PROFILE}" \
    --query "Policies[?contains(PolicyName, '${PROJECT_NAME}') || contains(PolicyName, '${CLUSTER_NAME_EAST}')].PolicyName" \
    --output text)

if [[ -z "$IAM_POLICIES" ]]; then
    print_info "No IAM policies found"
else
    print_error "Found IAM policies:"
    echo "$IAM_POLICIES" | tr '\t' '\n'
    FOUND_RESOURCES=$((FOUND_RESOURCES + 1))
fi

#######################################
# 6. IAM Roles
#######################################
print_header "6. Checking IAM Roles"

IAM_ROLES=$(aws iam list-roles \
    --profile "${AWS_PROFILE}" \
    --query "Roles[?contains(RoleName, 'eksctl-${CLUSTER_NAME_EAST}')].RoleName" \
    --output text)

if [[ -z "$IAM_ROLES" ]]; then
    print_info "No IAM roles found"
else
    print_error "Found IAM roles:"
    echo "$IAM_ROLES" | tr '\t' '\n'
    FOUND_RESOURCES=$((FOUND_RESOURCES + 1))
fi

#######################################
# 7. EBS Volumes
#######################################
print_header "7. Checking EBS Volumes"

EBS_VOLUMES=$(aws ec2 describe-volumes \
    --region "${AWS_REGION_EAST}" \
    --profile "${AWS_PROFILE}" \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME_EAST},Values=owned" \
    --query 'Volumes[].{ID:VolumeId,State:State,Size:Size}' \
    --output table 2>/dev/null)

if echo "$EBS_VOLUMES" | grep -q "vol-"; then
    print_error "Found EBS volumes:"
    echo "$EBS_VOLUMES"
    FOUND_RESOURCES=$((FOUND_RESOURCES + 1))
else
    print_info "No EBS volumes found"
fi

#######################################
# 8. Load Balancers
#######################################
print_header "8. Checking Load Balancers"

LOAD_BALANCERS=$(aws elbv2 describe-load-balancers \
    --region "${AWS_REGION_EAST}" \
    --profile "${AWS_PROFILE}" \
    --query "LoadBalancers[?contains(LoadBalancerName, '${PROJECT_NAME}')].LoadBalancerName" \
    --output text 2>/dev/null)

if [[ -z "$LOAD_BALANCERS" ]]; then
    print_info "No load balancers found"
else
    print_error "Found load balancers:"
    echo "$LOAD_BALANCERS" | tr '\t' '\n'
    FOUND_RESOURCES=$((FOUND_RESOURCES + 1))
fi

#######################################
# 9. VPCs (tagged with cluster)
#######################################
print_header "9. Checking VPCs"

VPCS=$(aws ec2 describe-vpcs \
    --region "${AWS_REGION_EAST}" \
    --profile "${AWS_PROFILE}" \
    --filters "Name=tag:alpha.eksctl.io/cluster-name,Values=${CLUSTER_NAME_EAST}" \
    --query 'Vpcs[].VpcId' \
    --output text 2>/dev/null)

if [[ -z "$VPCS" ]]; then
    print_info "No VPCs found"
else
    print_error "Found VPCs:"
    echo "$VPCS" | tr '\t' '\n'
    FOUND_RESOURCES=$((FOUND_RESOURCES + 1))
fi

#######################################
# 10. Security Groups
#######################################
print_header "10. Checking Security Groups"

SECURITY_GROUPS=$(aws ec2 describe-security-groups \
    --region "${AWS_REGION_EAST}" \
    --profile "${AWS_PROFILE}" \
    --filters "Name=tag:alpha.eksctl.io/cluster-name,Values=${CLUSTER_NAME_EAST}" \
    --query 'SecurityGroups[].GroupId' \
    --output text 2>/dev/null)

if [[ -z "$SECURITY_GROUPS" ]]; then
    print_info "No security groups found"
else
    print_error "Found security groups:"
    echo "$SECURITY_GROUPS" | tr '\t' '\n'
    FOUND_RESOURCES=$((FOUND_RESOURCES + 1))
fi

#######################################
# Summary
#######################################
print_header "Cleanup Verification Summary"

if [[ $FOUND_RESOURCES -eq 0 ]] && [[ $IN_PROGRESS_RESOURCES -eq 0 ]]; then
    print_info "✓ All resources cleaned up successfully!"
    print_info "Project ${PROJECT_NAME} has been completely removed"
    exit 0
elif [[ $FOUND_RESOURCES -eq 0 ]] && [[ $IN_PROGRESS_RESOURCES -gt 0 ]]; then
    print_warning "⏳ Cleanup in progress"
    print_info "Found $IN_PROGRESS_RESOURCES resource type(s) currently deleting"
    print_info "Wait a few minutes and run this script again to verify completion"
    exit 2
else
    print_error "✗ Found $FOUND_RESOURCES resource type(s) in error state"
    if [[ $IN_PROGRESS_RESOURCES -gt 0 ]]; then
        print_warning "Also found $IN_PROGRESS_RESOURCES resource type(s) currently deleting"
    fi
    print_warning "Review the output above for details"
    print_info "Run ./teardown.sh again to retry cleanup"
    exit 1
fi
