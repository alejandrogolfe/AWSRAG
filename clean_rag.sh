#!/bin/bash
set +e

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo -e "${RED}========================================${NC}"
echo -e "${RED} RAG SYSTEM CLEANUP${NC}"
echo -e "${RED}========================================${NC}"
echo -e "${RED}WARNING: This will delete ALL resources${NC}"
echo ""
read -p "Are you sure? (type 'DELETE' to confirm): " confirm
[ "$confirm" != "DELETE" ] && echo "Cleanup cancelled" && exit 0

if [ -f .rag-deployment-config ]; then
    source .rag-deployment-config
    echo -e "${GREEN}Loaded config${NC}"
else
    export AWS_REGION="${AWS_REGION:-eu-west-1}"
    export PROJECT_NAME="${PROJECT_NAME:-rag-system-alejandrogolfe}"
    export BUCKET_NAME="${BUCKET_NAME:-${PROJECT_NAME}-docs}"
    export LAMBDA_PROCESSOR="${LAMBDA_PROCESSOR:-${PROJECT_NAME}-processor}"
    export DB_INSTANCE_NAME="${DB_INSTANCE_NAME:-${PROJECT_NAME}-postgres}"
    export EC2_ROLE_NAME="${EC2_ROLE_NAME:-${PROJECT_NAME}-ec2-role}"
    export EC2_INSTANCE_PROFILE="${EC2_INSTANCE_PROFILE:-${PROJECT_NAME}-ec2-profile}"
fi

export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
[ -z "$AWS_ACCOUNT_ID" ] && echo -e "${RED}Error: AWS CLI no configurado${NC}" && exit 1

echo -e "\n${BLUE}Region: ${AWS_REGION} | Project: ${PROJECT_NAME}${NC}\n"

safe_delete() {
    local desc=$1; local cmd=$2
    echo -e "\n${BLUE}${desc}...${NC}"
    eval "$cmd" 2>/dev/null && echo -e "${GREEN}✓ ${desc}${NC}" || echo -e "${YELLOW}⚠ Ya eliminado o no encontrado${NC}"
}

# ============================================================
# 1. LAMBDA FUNCTION URL (si existía de versión anterior)
# ============================================================
echo -e "\n${BLUE}===== Step 1: Lambda Function URLs =====${NC}"
safe_delete "Eliminar function URL (si existe)" \
    "aws lambda delete-function-url-config --function-name ${LAMBDA_PROCESSOR} --region ${AWS_REGION}"

# ============================================================
# 2. S3 NOTIFICATION
# ============================================================
echo -e "\n${BLUE}===== Step 2: S3 Notifications =====${NC}"
safe_delete "Eliminar S3 notification" \
    "aws s3api put-bucket-notification-configuration --bucket ${BUCKET_NAME} --notification-configuration '{}' --region ${AWS_REGION}"

# ============================================================
# 3. LAMBDA PROCESSOR
# ============================================================
echo -e "\n${BLUE}===== Step 3: Lambda Processor =====${NC}"
safe_delete "Eliminar Lambda processor" \
    "aws lambda delete-function --function-name ${LAMBDA_PROCESSOR} --region ${AWS_REGION}"

echo -e "${YELLOW}Esperando 30s para que Lambda libere ENIs...${NC}"
sleep 30

# ============================================================
# 4. S3 BUCKET
# ============================================================
echo -e "\n${BLUE}===== Step 4: S3 Bucket =====${NC}"
echo "Vaciando bucket..."
aws s3 rm s3://${BUCKET_NAME} --recursive --region ${AWS_REGION} 2>/dev/null || true
safe_delete "Eliminar S3 bucket" \
    "aws s3 rb s3://${BUCKET_NAME} --region ${AWS_REGION}"

# ============================================================
# 5. ECR REPOSITORY
# ============================================================
echo -e "\n${BLUE}===== Step 5: ECR Repository =====${NC}"
safe_delete "Eliminar ECR processor" \
    "aws ecr delete-repository --repository-name ${PROJECT_NAME}-processor --force --region ${AWS_REGION}"

# ============================================================
# 6. EC2 STREAMLIT
# ============================================================
echo -e "\n${BLUE}===== Step 6: EC2 Streamlit =====${NC}"

# Buscar EC2 por tag si no está en config
if [ -z "$EC2_INSTANCE_ID" ] || [ "$EC2_INSTANCE_ID" = "None" ]; then
  EC2_INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${PROJECT_NAME}-streamlit" \
              "Name=instance-state-name,Values=running,stopped,stopping" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text --region ${AWS_REGION} 2>/dev/null)
fi

if [ ! -z "$EC2_INSTANCE_ID" ] && [ "$EC2_INSTANCE_ID" != "None" ]; then
  echo "Terminando EC2: ${EC2_INSTANCE_ID}..."
  aws ec2 terminate-instances --instance-ids ${EC2_INSTANCE_ID} --region ${AWS_REGION} 2>/dev/null
  aws ec2 wait instance-terminated --instance-ids ${EC2_INSTANCE_ID} --region ${AWS_REGION} 2>/dev/null && \
    echo -e "${GREEN}✓ EC2 terminada${NC}" || echo -e "${YELLOW}⚠ Timeout esperando EC2${NC}"
else
  echo -e "${YELLOW}⚠ EC2 Streamlit no encontrada${NC}"
fi

# Security Group EC2
EC2_SG_ID_CLEAN="${EC2_SG_ID:-}"
if [ -z "$EC2_SG_ID_CLEAN" ] || [ "$EC2_SG_ID_CLEAN" = "None" ]; then
  EC2_SG_ID_CLEAN=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${PROJECT_NAME}-streamlit-sg" \
    --query 'SecurityGroups[0].GroupId' --output text --region ${AWS_REGION} 2>/dev/null)
fi
if [ ! -z "$EC2_SG_ID_CLEAN" ] && [ "$EC2_SG_ID_CLEAN" != "None" ]; then
  for i in {1..4}; do
    aws ec2 delete-security-group --group-id ${EC2_SG_ID_CLEAN} --region ${AWS_REGION} 2>/dev/null && \
      echo -e "${GREEN}✓ EC2 Security Group eliminado${NC}" && break || \
      { [ $i -lt 4 ] && echo -e "${YELLOW}Reintentando en 10s... ($i/4)${NC}" && sleep 10; }
  done
fi

# IAM Instance Profile y Role EC2
echo "Eliminando IAM Instance Profile y rol EC2..."
aws iam remove-role-from-instance-profile \
  --instance-profile-name ${EC2_INSTANCE_PROFILE} \
  --role-name ${EC2_ROLE_NAME} 2>/dev/null || true
safe_delete "Eliminar Instance Profile EC2" \
  "aws iam delete-instance-profile --instance-profile-name ${EC2_INSTANCE_PROFILE}"
aws iam detach-role-policy --role-name ${EC2_ROLE_NAME} \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess 2>/dev/null || true
safe_delete "Eliminar IAM role EC2" \
  "aws iam delete-role --role-name ${EC2_ROLE_NAME}"

# ============================================================
# 7. RDS POSTGRES
# ============================================================
echo -e "\n${BLUE}===== Step 7: RDS Postgres =====${NC}"
aws rds delete-db-instance \
  --db-instance-identifier ${DB_INSTANCE_NAME} \
  --skip-final-snapshot --delete-automated-backups \
  --region ${AWS_REGION} 2>/dev/null && echo "RDS deletion initiated" || echo "RDS no encontrado"
echo "Esperando eliminación RDS (máx 10 min)..."
timeout 600 aws rds wait db-instance-deleted \
  --db-instance-identifier ${DB_INSTANCE_NAME} --region ${AWS_REGION} 2>/dev/null || true
echo -e "${GREEN}✓ RDS eliminado${NC}"

# ============================================================
# 8. DB SUBNET GROUP
# ============================================================
echo -e "\n${BLUE}===== Step 8: DB Subnet Group =====${NC}"
safe_delete "Eliminar DB subnet group" \
    "aws rds delete-db-subnet-group --db-subnet-group-name ${PROJECT_NAME}-subnet-group --region ${AWS_REGION}"

# ============================================================
# 9. SECURITY GROUP DB + LAMBDA
# ============================================================
echo -e "\n${BLUE}===== Step 9: Security Group DB =====${NC}"
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${PROJECT_NAME}-aurora-sg" \
  --query 'SecurityGroups[0].GroupId' --output text --region ${AWS_REGION} 2>/dev/null)

if [ ! -z "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
  RULES=$(aws ec2 describe-security-groups --group-ids ${SG_ID} --region ${AWS_REGION} \
    --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)
  if [ "$RULES" != "[]" ] && [ ! -z "$RULES" ]; then
    echo "$RULES" > /tmp/sg_rules.json
    aws ec2 revoke-security-group-ingress --group-id ${SG_ID} \
      --ip-permissions file:///tmp/sg_rules.json --region ${AWS_REGION} 2>/dev/null || true
  fi
  for i in {1..5}; do
    aws ec2 delete-security-group --group-id ${SG_ID} --region ${AWS_REGION} 2>/dev/null && \
      echo -e "${GREEN}✓ DB Security Group eliminado${NC}" && break || \
      { [ $i -lt 5 ] && echo -e "${YELLOW}Reintentando en 15s... ($i/5)${NC}" && sleep 15; }
  done
else
  echo -e "${YELLOW}⚠ DB Security Group no encontrado${NC}"
fi

# ============================================================
# 10. IAM ROLE LAMBDA
# ============================================================
echo -e "\n${BLUE}===== Step 10: IAM Role Lambda =====${NC}"
ROLE_NAME="${PROJECT_NAME}-lambda-role"
ATTACHED=$(aws iam list-attached-role-policies --role-name ${ROLE_NAME} \
  --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null)
for p in $ATTACHED; do
  aws iam detach-role-policy --role-name ${ROLE_NAME} --policy-arn $p 2>/dev/null || true
done
INLINE=$(aws iam list-role-policies --role-name ${ROLE_NAME} \
  --query 'PolicyNames' --output text 2>/dev/null)
for p in $INLINE; do
  aws iam delete-role-policy --role-name ${ROLE_NAME} --policy-name $p 2>/dev/null || true
done
safe_delete "Eliminar IAM role Lambda" "aws iam delete-role --role-name ${ROLE_NAME}"

# ============================================================
# 11. ARCHIVOS LOCALES
# ============================================================
echo -e "\n${BLUE}===== Step 11: Archivos locales =====${NC}"
rm -f .rag-deployment-config lambda-role-trust.json lambda-vpc-policy.json \
      s3-notification.json ec2-userdata.sh /tmp/sg_rules.json 2>/dev/null
echo -e "${GREEN}✓ Archivos locales eliminados${NC}"

# ============================================================
# RESUMEN
# ============================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} CLEANUP COMPLETADO${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${GREEN}Recursos eliminados:${NC}"
echo "  ✓ Lambda Processor"
echo "  ✓ S3 Bucket y contenidos"
echo "  ✓ ECR Repository"
echo "  ✓ RDS PostgreSQL"
echo "  ✓ EC2 Streamlit"
echo "  ✓ Security Groups (DB + EC2)"
echo "  ✓ IAM Roles (Lambda + EC2) y Instance Profile"
echo "  ✓ Archivos locales"
echo ""
echo -e "${YELLOW}Nota: Algunos recursos tardan unos minutos en eliminarse completamente.${NC}"
echo -e "${YELLOW}Si algo falla, vuelve a ejecutar: ./clean_rag.sh${NC}"
echo ""
echo -e "${BLUE}Para redesplegar: ./deploy_rag.sh${NC}"
