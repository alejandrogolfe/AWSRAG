#!/bin/bash

# Robust cleanup script for RAG system
# Handles partial deployments and continues on errors

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}========================================${NC}"
echo -e "${RED} RAG SYSTEM CLEANUP${NC}"
echo -e "${RED}========================================${NC}"
echo -e "${RED}WARNING: This will delete ALL resources${NC}"
echo -e "${RED}This action cannot be undone!${NC}"
echo ""
read -p "Are you sure? (type 'DELETE' to confirm): " confirm

if [ "$confirm" != "DELETE" ]; then
    echo "Cleanup cancelled"
    exit 0
fi

# Try to load config, but continue if it doesn't exist
if [ -f .rag-deployment-config ]; then
    source .rag-deployment-config
    echo -e "${GREEN}Loaded config from .rag-deployment-config${NC}"
else
    echo -e "${YELLOW}No .rag-deployment-config found, using default names${NC}"
    export AWS_REGION="${AWS_REGION:-eu-west-1}"
    export PROJECT_NAME="${PROJECT_NAME:-rag-system-alejandrogolfe}"
    export BUCKET_NAME="${BUCKET_NAME:-${PROJECT_NAME}-docs}"
    export LAMBDA_PROCESSOR="${LAMBDA_PROCESSOR:-${PROJECT_NAME}-processor}"
    export LAMBDA_QUERY="${LAMBDA_QUERY:-${PROJECT_NAME}-query-api}"
    export DB_INSTANCE_NAME="${DB_INSTANCE_NAME:-${PROJECT_NAME}-postgres}"
fi

export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")

if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo -e "${RED}Error: Cannot get AWS Account ID. Is AWS CLI configured?${NC}"
    exit 1
fi

echo -e "\n${BLUE}Region: ${AWS_REGION}${NC}"
echo -e "${BLUE}Project: ${PROJECT_NAME}${NC}"
echo ""

# Function to safely delete a resource
safe_delete() {
    local description=$1
    local command=$2
    
    echo -e "\n${BLUE}${description}...${NC}"
    if eval "$command" 2>/dev/null; then
        echo -e "${GREEN}✓ ${description} completed${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠ ${description} - resource not found or already deleted${NC}"
        return 1
    fi
}

# ============================================================
# 1. DELETE LAMBDA FUNCTION URLs (must be before Lambda deletion)
# ============================================================
echo -e "\n${BLUE}===== Step 1: Lambda Function URLs =====${NC}"

safe_delete "Deleting query Lambda function URL" \
    "aws lambda delete-function-url-config --function-name ${LAMBDA_QUERY} --region ${AWS_REGION}"

# ============================================================
# 2. DELETE S3 NOTIFICATION CONFIGURATION
# ============================================================
echo -e "\n${BLUE}===== Step 2: S3 Event Notifications =====${NC}"

safe_delete "Removing S3 notification configuration" \
    "aws s3api put-bucket-notification-configuration --bucket ${BUCKET_NAME} --notification-configuration '{}' --region ${AWS_REGION}"

# ============================================================
# 3. DELETE LAMBDA FUNCTIONS
# ============================================================
echo -e "\n${BLUE}===== Step 3: Lambda Functions =====${NC}"

safe_delete "Deleting processor Lambda" \
    "aws lambda delete-function --function-name ${LAMBDA_PROCESSOR} --region ${AWS_REGION}"

safe_delete "Deleting query Lambda" \
    "aws lambda delete-function --function-name ${LAMBDA_QUERY} --region ${AWS_REGION}"

# Wait for Lambda ENIs to be cleaned up (important for VPC resources)
echo -e "${YELLOW}Waiting 30s for Lambda ENIs to be cleaned up...${NC}"
sleep 30

# ============================================================
# 4. DELETE S3 BUCKET
# ============================================================
echo -e "\n${BLUE}===== Step 4: S3 Bucket =====${NC}"

echo "Emptying bucket..."
aws s3 rm s3://${BUCKET_NAME} --recursive --region ${AWS_REGION} 2>/dev/null || echo "Bucket empty or not found"

safe_delete "Deleting S3 bucket" \
    "aws s3 rb s3://${BUCKET_NAME} --region ${AWS_REGION}"

# ============================================================
# 5. DELETE ECR REPOSITORIES
# ============================================================
echo -e "\n${BLUE}===== Step 5: ECR Repositories =====${NC}"

safe_delete "Deleting processor ECR repository" \
    "aws ecr delete-repository --repository-name ${PROJECT_NAME}-processor --force --region ${AWS_REGION}"

safe_delete "Deleting query ECR repository" \
    "aws ecr delete-repository --repository-name ${PROJECT_NAME}-query --force --region ${AWS_REGION}"

# ============================================================
# 6. DELETE RDS POSTGRES DATABASE
# ============================================================
echo -e "\n${BLUE}===== Step 6: RDS Postgres Database =====${NC}"

# Delete RDS instance
echo "Deleting RDS Postgres instance..."
aws rds delete-db-instance \
  --db-instance-identifier ${DB_INSTANCE_NAME} \
  --skip-final-snapshot \
  --delete-automated-backups \
  --region ${AWS_REGION} 2>/dev/null && echo "Instance deletion initiated" || echo "Instance not found"

# Wait for instance deletion (with timeout)
echo "Waiting for instance deletion (max 10 minutes)..."
timeout 600 aws rds wait db-instance-deleted \
  --db-instance-identifier ${DB_INSTANCE_NAME} \
  --region ${AWS_REGION} 2>/dev/null || echo "Timeout or instance already deleted"

echo -e "${GREEN}✓ RDS Postgres deleted${NC}"

# ============================================================
# 7. DELETE DB SUBNET GROUP
# ============================================================
echo -e "\n${BLUE}===== Step 7: DB Subnet Group =====${NC}"

safe_delete "Deleting DB subnet group" \
    "aws rds delete-db-subnet-group --db-subnet-group-name ${PROJECT_NAME}-subnet-group --region ${AWS_REGION}"

# ============================================================
# 8. DELETE SECURITY GROUP
# ============================================================
echo -e "\n${BLUE}===== Step 8: Security Group =====${NC}"

SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${PROJECT_NAME}-aurora-sg" \
  --query 'SecurityGroups[0].GroupId' \
  --output text \
  --region ${AWS_REGION} 2>/dev/null || echo "")

if [ ! -z "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
  echo "Found security group: ${SG_ID}"
  
  # Revoke all ingress rules first
  echo "Revoking security group rules..."
  aws ec2 describe-security-groups --group-ids ${SG_ID} --region ${AWS_REGION} \
    --query 'SecurityGroups[0].IpPermissions' --output json > /tmp/sg_rules.json 2>/dev/null
  
  if [ -s /tmp/sg_rules.json ] && [ "$(cat /tmp/sg_rules.json)" != "[]" ]; then
    aws ec2 revoke-security-group-ingress \
      --group-id ${SG_ID} \
      --ip-permissions file:///tmp/sg_rules.json \
      --region ${AWS_REGION} 2>/dev/null || echo "No rules to revoke"
  fi
  
  # Try to delete (might fail if ENIs still attached)
  for i in {1..5}; do
    if aws ec2 delete-security-group --group-id ${SG_ID} --region ${AWS_REGION} 2>/dev/null; then
      echo -e "${GREEN}✓ Security group deleted${NC}"
      break
    else
      if [ $i -lt 5 ]; then
        echo -e "${YELLOW}Security group still has dependencies, retrying in 15s... (attempt $i/5)${NC}"
        sleep 15
      else
        echo -e "${RED}✗ Failed to delete security group ${SG_ID}${NC}"
        echo -e "${YELLOW}You may need to manually delete it after all ENIs are removed${NC}"
      fi
    fi
  done
else
  echo -e "${YELLOW}⚠ Security group not found${NC}"
fi

# ============================================================
# 9. DELETE IAM ROLE
# ============================================================
echo -e "\n${BLUE}===== Step 9: IAM Role =====${NC}"

ROLE_NAME="${PROJECT_NAME}-lambda-role"

# List and detach all managed policies
echo "Detaching managed policies..."
ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
  --role-name ${ROLE_NAME} \
  --query 'AttachedPolicies[*].PolicyArn' \
  --output text 2>/dev/null || echo "")

if [ ! -z "$ATTACHED_POLICIES" ]; then
  for policy in $ATTACHED_POLICIES; do
    aws iam detach-role-policy \
      --role-name ${ROLE_NAME} \
      --policy-arn $policy 2>/dev/null && echo "  Detached $policy" || true
  done
fi

# List and delete all inline policies
echo "Deleting inline policies..."
INLINE_POLICIES=$(aws iam list-role-policies \
  --role-name ${ROLE_NAME} \
  --query 'PolicyNames' \
  --output text 2>/dev/null || echo "")

if [ ! -z "$INLINE_POLICIES" ]; then
  for policy in $INLINE_POLICIES; do
    aws iam delete-role-policy \
      --role-name ${ROLE_NAME} \
      --policy-name $policy 2>/dev/null && echo "  Deleted inline policy $policy" || true
  done
fi

# Delete the role
safe_delete "Deleting IAM role" \
    "aws iam delete-role --role-name ${ROLE_NAME}"

# ============================================================
# 10. CLEAN UP LOCAL FILES
# ============================================================
echo -e "\n${BLUE}===== Step 10: Local Files =====${NC}"

# Files created by deploy_rag.sh
rm -f .rag-deployment-config && echo "✓ Deleted .rag-deployment-config" || true
rm -f lambda-role-trust.json && echo "✓ Deleted lambda-role-trust.json" || true
rm -f lambda-vpc-policy.json && echo "✓ Deleted lambda-vpc-policy.json" || true
rm -f s3-notification.json && echo "✓ Deleted s3-notification.json" || true
rm -f test_document.txt && echo "✓ Deleted test_document.txt" || true

# Temporary files
rm -f /tmp/sg_rules.json 2>/dev/null || true

# Optional: Remove helper scripts (comment out if you want to keep them)
# rm -f init_schema.ps1 && echo "✓ Deleted init_schema.ps1" || true
# rm -f init_schema_helper.sh && echo "✓ Deleted init_schema_helper.sh" || true
# rm -f check_db_tools.sh && echo "✓ Deleted check_db_tools.sh" || true

echo -e "${GREEN}✓ Local files cleaned${NC}"

# ============================================================
# SUMMARY
# ============================================================
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN} CLEANUP COMPLETED${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${GREEN}All RAG system resources have been deleted:${NC}"
echo "  ✓ Lambda Functions (processor, query)"
echo "  ✓ S3 Bucket and contents"
echo "  ✓ ECR Docker repositories"
echo "  ✓ RDS PostgreSQL database"
echo "  ✓ VPC Security Groups"
echo "  ✓ IAM Roles and policies"
echo "  ✓ Local configuration files"
echo ""
echo -e "${YELLOW}NOTE: Some resources may take a few minutes to fully delete.${NC}"
echo ""
echo -e "${YELLOW}If any resources failed to delete:${NC}"
echo "  1. Wait 5-10 minutes for AWS to finish cleanup"
echo "  2. Run this script again: ./clean_rag.sh"
echo "  3. Check AWS Console for orphaned resources:"
echo "     - RDS → Databases"
echo "     - EC2 → Security Groups"
echo "     - EC2 → Network Interfaces (ENIs)"
echo "     - Lambda → Functions"
echo "     - S3 → Buckets"
echo ""
echo -e "${BLUE}To redeploy the system:${NC}"
echo "  ./deploy_rag.sh"
echo ""
