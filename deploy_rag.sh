#!/bin/bash
set -e

# ============================================================
# CONFIGURACION - CAMBIA ESTOS VALORES
# ============================================================
export AWS_REGION="eu-west-1"
export PROJECT_NAME="rag-system"
export BUCKET_NAME="${PROJECT_NAME}-docs"
export ECR_REPO_PROCESSOR="${PROJECT_NAME}-processor"
export ECR_REPO_QUERY="${PROJECT_NAME}-query"
export LAMBDA_PROCESSOR="${PROJECT_NAME}-processor"
export LAMBDA_QUERY="${PROJECT_NAME}-query-api"

# Database configuration
export DB_NAME="ragdb"
export DB_USER="ragadmin"
export DB_PASSWORD="RagSecurePass$(date +%s)"  # Generate random password
export DB_CLUSTER_NAME="${PROJECT_NAME}-aurora"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE} RAG SYSTEM DEPLOYMENT${NC}"
echo -e "${BLUE}========================================${NC}"

export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo -e "${GREEN}Account ID: ${AWS_ACCOUNT_ID}${NC}"

# ============================================================
# PASO 1: CREAR BUCKET S3
# ============================================================
echo -e "\n${BLUE}PASO 1: Creando bucket S3...${NC}"
aws s3 mb s3://${BUCKET_NAME} --region ${AWS_REGION} 2>/dev/null || echo "Bucket ya existe"
echo -e "${GREEN}Bucket: ${BUCKET_NAME}${NC}"

aws s3api put-object --bucket ${BUCKET_NAME} --key docs/ --region ${AWS_REGION} 2>/dev/null || true
echo -e "${GREEN}Carpeta docs/ lista${NC}"

# ============================================================
# PASO 2: CREAR REPOSITORIOS ECR
# ============================================================
echo -e "\n${BLUE}PASO 2: Creando repositorios ECR...${NC}"
aws ecr create-repository \
  --repository-name ${ECR_REPO_PROCESSOR} \
  --region ${AWS_REGION} 2>/dev/null || echo "Repo processor ya existe"

aws ecr create-repository \
  --repository-name ${ECR_REPO_QUERY} \
  --region ${AWS_REGION} 2>/dev/null || echo "Repo query ya existe"

echo -e "${GREEN}ECR Repos creados${NC}"

# ============================================================
# PASO 3: BUILD Y PUSH IMAGENES DOCKER
# ============================================================
echo -e "\n${BLUE}PASO 3: Building imágenes Docker...${NC}"

aws ecr get-login-password --region ${AWS_REGION} | \
  docker login --username AWS --password-stdin \
  ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

# Build processor
cd processor
docker build -t ${ECR_REPO_PROCESSOR} .
docker tag ${ECR_REPO_PROCESSOR}:latest \
  ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_PROCESSOR}:latest
docker push ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_PROCESSOR}:latest
echo -e "${GREEN}Processor image pushed${NC}"

# Build query
cd ../query
docker build -t ${ECR_REPO_QUERY} .
docker tag ${ECR_REPO_QUERY}:latest \
  ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_QUERY}:latest
docker push ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_QUERY}:latest
echo -e "${GREEN}Query image pushed${NC}"

cd ..

# ============================================================
# PASO 4: CREAR VPC SECURITY GROUP PARA AURORA
# ============================================================
echo -e "\n${BLUE}PASO 4: Configurando networking para Aurora...${NC}"

# Get default VPC
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" \
  --query 'Vpcs[0].VpcId' --output text --region ${AWS_REGION})

# Create security group for Aurora
SG_ID=$(aws ec2 create-security-group \
  --group-name ${PROJECT_NAME}-aurora-sg \
  --description "Security group for RAG Aurora cluster" \
  --vpc-id ${VPC_ID} \
  --region ${AWS_REGION} \
  --query 'GroupId' --output text 2>/dev/null || \
  aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${PROJECT_NAME}-aurora-sg" \
    --query 'SecurityGroups[0].GroupId' --output text --region ${AWS_REGION})

# Allow inbound Postgres from same security group (Lambda will use this SG)
aws ec2 authorize-security-group-ingress \
  --group-id ${SG_ID} \
  --protocol tcp \
  --port 5432 \
  --source-group ${SG_ID} \
  --region ${AWS_REGION} 2>/dev/null || echo "Ingress rule already exists"

echo -e "${GREEN}Security Group: ${SG_ID}${NC}"

# Get subnets for Aurora
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[*].SubnetId' \
  --output text --region ${AWS_REGION})

SUBNET_ARRAY=($SUBNET_IDS)

# Create DB subnet group
aws rds create-db-subnet-group \
  --db-subnet-group-name ${PROJECT_NAME}-subnet-group \
  --db-subnet-group-description "Subnet group for RAG Aurora" \
  --subnet-ids ${SUBNET_IDS} \
  --region ${AWS_REGION} 2>/dev/null || echo "Subnet group ya existe"

echo -e "${GREEN}Networking configurado${NC}"

# ============================================================
# PASO 5: CREAR AURORA SERVERLESS V2 CLUSTER
# ============================================================
echo -e "\n${BLUE}PASO 5: Creando Aurora Serverless v2...${NC}"

EXISTING_CLUSTER=$(aws rds describe-db-clusters \
  --db-cluster-identifier ${DB_CLUSTER_NAME} \
  --query 'DBClusters[0].DBClusterIdentifier' \
  --output text --region ${AWS_REGION} 2>/dev/null || echo "")

if [ "$EXISTING_CLUSTER" = "${DB_CLUSTER_NAME}" ]; then
  echo -e "${GREEN}Aurora cluster ya existe, reutilizando${NC}"
  DB_ENDPOINT=$(aws rds describe-db-clusters \
    --db-cluster-identifier ${DB_CLUSTER_NAME} \
    --query 'DBClusters[0].Endpoint' \
    --output text --region ${AWS_REGION})
else
  # Create Aurora cluster
  aws rds create-db-cluster \
    --db-cluster-identifier ${DB_CLUSTER_NAME} \
    --engine aurora-postgresql \
    --engine-version 15.5 \
    --master-username ${DB_USER} \
    --master-user-password ${DB_PASSWORD} \
    --database-name ${DB_NAME} \
    --db-subnet-group-name ${PROJECT_NAME}-subnet-group \
    --vpc-security-group-ids ${SG_ID} \
    --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=1 \
    --region ${AWS_REGION}

  echo "Esperando a que Aurora cluster esté disponible (esto puede tardar 5-10 minutos)..."
  aws rds wait db-cluster-available \
    --db-cluster-identifier ${DB_CLUSTER_NAME} \
    --region ${AWS_REGION}

  # Create DB instance
  aws rds create-db-instance \
    --db-instance-identifier ${DB_CLUSTER_NAME}-instance \
    --db-instance-class db.serverless \
    --engine aurora-postgresql \
    --db-cluster-identifier ${DB_CLUSTER_NAME} \
    --region ${AWS_REGION}

  echo "Esperando a que instancia esté disponible..."
  aws rds wait db-instance-available \
    --db-instance-identifier ${DB_CLUSTER_NAME}-instance \
    --region ${AWS_REGION}

  DB_ENDPOINT=$(aws rds describe-db-clusters \
    --db-cluster-identifier ${DB_CLUSTER_NAME} \
    --query 'DBClusters[0].Endpoint' \
    --output text --region ${AWS_REGION})

  echo -e "${GREEN}Aurora Serverless v2 creado${NC}"
fi

echo -e "${GREEN}DB Endpoint: ${DB_ENDPOINT}${NC}"

# ============================================================
# PASO 6: INICIALIZAR BASE DE DATOS CON SCHEMA
# ============================================================
echo -e "\n${BLUE}PASO 6: Inicializando schema de base de datos...${NC}"

# Install psql if not available (for schema setup)
if ! command -v psql &> /dev/null; then
    echo "psql no encontrado. Instalando postgresql-client..."
    # This assumes Amazon Linux 2 / Ubuntu
    sudo yum install -y postgresql15 2>/dev/null || sudo apt-get install -y postgresql-client 2>/dev/null || echo "Instala postgresql-client manualmente"
fi

# Run schema.sql
PGPASSWORD=${DB_PASSWORD} psql -h ${DB_ENDPOINT} -U ${DB_USER} -d ${DB_NAME} -f schema.sql 2>/dev/null || \
  echo "NOTA: Ejecuta manualmente 'psql -h ${DB_ENDPOINT} -U ${DB_USER} -d ${DB_NAME} -f schema.sql' si falla"

echo -e "${GREEN}Schema inicializado${NC}"

# ============================================================
# PASO 7: CREAR ROLES IAM
# ============================================================
echo -e "\n${BLUE}PASO 7: Creando roles IAM...${NC}"

# Lambda execution role
cat > lambda-role-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
  --role-name ${PROJECT_NAME}-lambda-role \
  --assume-role-policy-document file://lambda-role-trust.json \
  --region ${AWS_REGION} 2>/dev/null || echo "Rol ya existe"

# Attach policies
aws iam attach-role-policy \
  --role-name ${PROJECT_NAME}-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

aws iam attach-role-policy \
  --role-name ${PROJECT_NAME}-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess

aws iam attach-role-policy \
  --role-name ${PROJECT_NAME}-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonBedrockFullAccess

# Create policy for VPC access
cat > lambda-vpc-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateNetworkInterface",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DeleteNetworkInterface",
        "ec2:AssignPrivateIpAddresses",
        "ec2:UnassignPrivateIpAddresses"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name ${PROJECT_NAME}-lambda-role \
  --policy-name LambdaVPCAccess \
  --policy-document file://lambda-vpc-policy.json

echo -e "${GREEN}Roles IAM creados${NC}"
echo "Esperando 10s para que los roles estén activos..."
sleep 10

# ============================================================
# PASO 8: CREAR LAMBDA PROCESSOR
# ============================================================
echo -e "\n${BLUE}PASO 8: Creando Lambda processor...${NC}"

EXISTING_LAMBDA=$(aws lambda get-function \
  --function-name ${LAMBDA_PROCESSOR} \
  --region ${AWS_REGION} \
  --query 'Configuration.FunctionName' \
  --output text 2>/dev/null || echo "")

if [ "$EXISTING_LAMBDA" = "${LAMBDA_PROCESSOR}" ]; then
  echo "Lambda processor ya existe, actualizando..."
  aws lambda update-function-code \
    --function-name ${LAMBDA_PROCESSOR} \
    --image-uri ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_PROCESSOR}:latest \
    --region ${AWS_REGION}
  
  aws lambda update-function-configuration \
    --function-name ${LAMBDA_PROCESSOR} \
    --environment "Variables={DB_HOST=${DB_ENDPOINT},DB_NAME=${DB_NAME},DB_USER=${DB_USER},DB_PASSWORD=${DB_PASSWORD},AWS_REGION=${AWS_REGION}}" \
    --region ${AWS_REGION}
else
  aws lambda create-function \
    --function-name ${LAMBDA_PROCESSOR} \
    --package-type Image \
    --code ImageUri=${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_PROCESSOR}:latest \
    --role arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PROJECT_NAME}-lambda-role \
    --timeout 900 \
    --memory-size 1024 \
    --vpc-config SubnetIds=${SUBNET_ARRAY[0]},${SUBNET_ARRAY[1]},SecurityGroupIds=${SG_ID} \
    --environment "Variables={DB_HOST=${DB_ENDPOINT},DB_NAME=${DB_NAME},DB_USER=${DB_USER},DB_PASSWORD=${DB_PASSWORD},AWS_REGION=${AWS_REGION}}" \
    --region ${AWS_REGION}
fi

echo -e "${GREEN}Lambda processor creada${NC}"

# ============================================================
# PASO 9: CREAR LAMBDA QUERY API
# ============================================================
echo -e "\n${BLUE}PASO 9: Creando Lambda query API...${NC}"

EXISTING_QUERY=$(aws lambda get-function \
  --function-name ${LAMBDA_QUERY} \
  --region ${AWS_REGION} \
  --query 'Configuration.FunctionName' \
  --output text 2>/dev/null || echo "")

if [ "$EXISTING_QUERY" = "${LAMBDA_QUERY}" ]; then
  echo "Lambda query ya existe, actualizando..."
  aws lambda update-function-code \
    --function-name ${LAMBDA_QUERY} \
    --image-uri ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_QUERY}:latest \
    --region ${AWS_REGION}
  
  aws lambda update-function-configuration \
    --function-name ${LAMBDA_QUERY} \
    --environment "Variables={DB_HOST=${DB_ENDPOINT},DB_NAME=${DB_NAME},DB_USER=${DB_USER},DB_PASSWORD=${DB_PASSWORD},AWS_REGION=${AWS_REGION}}" \
    --region ${AWS_REGION}
else
  aws lambda create-function \
    --function-name ${LAMBDA_QUERY} \
    --package-type Image \
    --code ImageUri=${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_QUERY}:latest \
    --role arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PROJECT_NAME}-lambda-role \
    --timeout 300 \
    --memory-size 512 \
    --vpc-config SubnetIds=${SUBNET_ARRAY[0]},${SUBNET_ARRAY[1]},SecurityGroupIds=${SG_ID} \
    --environment "Variables={DB_HOST=${DB_ENDPOINT},DB_NAME=${DB_NAME},DB_USER=${DB_USER},DB_PASSWORD=${DB_PASSWORD},AWS_REGION=${AWS_REGION}}" \
    --region ${AWS_REGION}
fi

echo -e "${GREEN}Lambda query API creada${NC}"

# ============================================================
# PASO 10: CONFIGURAR S3 TRIGGER
# ============================================================
echo -e "\n${BLUE}PASO 10: Configurando trigger S3 -> Lambda...${NC}"

aws lambda add-permission \
  --function-name ${LAMBDA_PROCESSOR} \
  --statement-id s3-trigger \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn arn:aws:s3:::${BUCKET_NAME} \
  --region ${AWS_REGION} 2>/dev/null || echo "Permiso S3 ya existe"

cat > s3-notification.json << EOF
{
  "LambdaFunctionConfigurations": [{
    "LambdaFunctionArn": "arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:${LAMBDA_PROCESSOR}",
    "Events": ["s3:ObjectCreated:*"],
    "Filter": {
      "Key": {
        "FilterRules": [{"Name": "prefix", "Value": "docs/"}]
      }
    }
  }]
}
EOF

aws s3api put-bucket-notification-configuration \
  --bucket ${BUCKET_NAME} \
  --notification-configuration file://s3-notification.json

echo -e "${GREEN}Trigger S3 configurado${NC}"

# ============================================================
# PASO 11: CREAR FUNCTION URL PARA QUERY API
# ============================================================
echo -e "\n${BLUE}PASO 11: Creando Function URL para query API...${NC}"

FUNCTION_URL=$(aws lambda create-function-url-config \
  --function-name ${LAMBDA_QUERY} \
  --auth-type NONE \
  --cors AllowOrigins="*",AllowMethods="POST",AllowHeaders="*" \
  --region ${AWS_REGION} \
  --query 'FunctionUrl' \
  --output text 2>/dev/null || \
  aws lambda get-function-url-config \
    --function-name ${LAMBDA_QUERY} \
    --region ${AWS_REGION} \
    --query 'FunctionUrl' \
    --output text)

aws lambda add-permission \
  --function-name ${LAMBDA_QUERY} \
  --statement-id FunctionURLAllowPublicAccess \
  --action lambda:InvokeFunctionUrl \
  --principal "*" \
  --function-url-auth-type NONE \
  --region ${AWS_REGION} 2>/dev/null || echo "Permission already exists"

echo -e "${GREEN}Function URL: ${FUNCTION_URL}${NC}"

# ============================================================
# RESUMEN
# ============================================================
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN} DESPLIEGUE RAG COMPLETADO${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "  ${BLUE}S3 Bucket:${NC}       ${BUCKET_NAME}"
echo -e "  ${BLUE}Aurora Endpoint:${NC} ${DB_ENDPOINT}"
echo -e "  ${BLUE}DB Name:${NC}         ${DB_NAME}"
echo -e "  ${BLUE}DB User:${NC}         ${DB_USER}"
echo -e "  ${BLUE}DB Password:${NC}     ${DB_PASSWORD}"
echo -e "  ${BLUE}Lambda Processor:${NC} ${LAMBDA_PROCESSOR}"
echo -e "  ${BLUE}Lambda Query:${NC}    ${LAMBDA_QUERY}"
echo -e "  ${BLUE}Query API URL:${NC}   ${FUNCTION_URL}"
echo ""
echo -e "${BLUE}PROBAR PROCESAMIENTO:${NC}"
echo "  aws s3 cp document.pdf s3://${BUCKET_NAME}/docs/document.pdf"
echo ""
echo -e "${BLUE}PROBAR QUERY:${NC}"
echo "  curl -X POST ${FUNCTION_URL} \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"question\": \"What is the main topic?\"}'"
echo ""
echo -e "${BLUE}VER LOGS:${NC}"
echo "  aws logs tail /aws/lambda/${LAMBDA_PROCESSOR} --follow"
echo "  aws logs tail /aws/lambda/${LAMBDA_QUERY} --follow"
echo ""

# Save config
cat > .rag-deployment-config << EOF
AWS_REGION=${AWS_REGION}
PROJECT_NAME=${PROJECT_NAME}
BUCKET_NAME=${BUCKET_NAME}
DB_ENDPOINT=${DB_ENDPOINT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
LAMBDA_PROCESSOR=${LAMBDA_PROCESSOR}
LAMBDA_QUERY=${LAMBDA_QUERY}
QUERY_API_URL=${FUNCTION_URL}
AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID}
EOF

echo -e "${GREEN}Configuración guardada en .rag-deployment-config${NC}"
