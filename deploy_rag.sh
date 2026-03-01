#!/bin/bash
# Don't exit on error - we want to continue even if some resources exist
set +e

# ============================================================
# CONFIGURACION - CAMBIA ESTOS VALORES
# ============================================================
export AWS_REGION="eu-west-1"
export PROJECT_NAME="rag-system-alejandrogolfe"
export BUCKET_NAME="${PROJECT_NAME}-docs"
export ECR_REPO_PROCESSOR="${PROJECT_NAME}-processor"
export ECR_REPO_QUERY="${PROJECT_NAME}-query"
export LAMBDA_PROCESSOR="${PROJECT_NAME}-processor"
export LAMBDA_QUERY="${PROJECT_NAME}-query-api"

# Database configuration
export DB_NAME="ragdb"
export DB_USER="ragadmin"
# Try to load existing password from config, otherwise generate new one
if [ -f .rag-deployment-config ]; then
    source .rag-deployment-config
    echo "Loaded existing password from config"
else
    export DB_PASSWORD="RagSecurePass$(date +%s)"
fi
export DB_INSTANCE_NAME="${PROJECT_NAME}-postgres"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE} RAG SYSTEM DEPLOYMENT${NC}"
echo -e "${BLUE}========================================${NC}"

# Detect environment
DETECTED_OS="unknown"
if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "win32" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
    DETECTED_OS="windows"
    echo -e "${YELLOW}⚠️  Detected: Windows/Git Bash${NC}"
    echo -e "${YELLOW}   If Docker commands fail, try running in PowerShell instead${NC}"
    echo -e "${YELLOW}   Command: bash deploy_rag.sh${NC}"
    echo ""
elif [[ "$OSTYPE" == "darwin"* ]]; then
    DETECTED_OS="macos"
    echo -e "${GREEN}Detected: macOS${NC}"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    DETECTED_OS="linux"
    echo -e "${GREEN}Detected: Linux${NC}"
fi

export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo -e "${GREEN}Account ID: ${AWS_ACCOUNT_ID}${NC}"

# ============================================================
# PASO 1: CREAR BUCKET S3
# ============================================================
echo -e "\n${BLUE}PASO 1: Verificando bucket S3...${NC}"
if aws s3 ls s3://${BUCKET_NAME} --region ${AWS_REGION} 2>/dev/null; then
    echo -e "${YELLOW}Bucket ya existe, skipping${NC}"
else
    aws s3 mb s3://${BUCKET_NAME} --region ${AWS_REGION}
    echo -e "${GREEN}Bucket creado: ${BUCKET_NAME}${NC}"
fi

aws s3api put-object --bucket ${BUCKET_NAME} --key docs/ --region ${AWS_REGION} 2>/dev/null || true
echo -e "${GREEN}Carpeta docs/ lista${NC}"

# ============================================================
# PASO 2: CREAR REPOSITORIOS ECR
# ============================================================
echo -e "\n${BLUE}PASO 2: Verificando repositorios ECR...${NC}"
aws ecr create-repository \
  --repository-name ${ECR_REPO_PROCESSOR} \
  --region ${AWS_REGION} 2>/dev/null && echo "Processor repo creado" || echo -e "${YELLOW}Processor repo ya existe${NC}"

aws ecr create-repository \
  --repository-name ${ECR_REPO_QUERY} \
  --region ${AWS_REGION} 2>/dev/null && echo "Query repo creado" || echo -e "${YELLOW}Query repo ya existe${NC}"

# ============================================================
# PASO 3: BUILD Y PUSH IMAGENES DOCKER (FIX FOR LAMBDA)
# ============================================================
echo -e "\n${BLUE}PASO 3: Building imágenes Docker para Lambda...${NC}"

# CRITICAL: Disable BuildKit to avoid Image Index manifests that Lambda doesn't support
export DOCKER_BUILDKIT=0
echo -e "${YELLOW}BuildKit disabled (DOCKER_BUILDKIT=0) to ensure Lambda compatibility${NC}"

aws ecr get-login-password --region ${AWS_REGION} | \
  docker login --username AWS --password-stdin \
  ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

# Build processor with explicit platform for Lambda
echo "Building processor image..."
cd processor
docker build \
  --platform linux/amd64 \
  --no-cache \
  -t ${ECR_REPO_PROCESSOR}:latest \
  .
docker tag ${ECR_REPO_PROCESSOR}:latest \
  ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_PROCESSOR}:latest
docker push ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_PROCESSOR}:latest
echo -e "${GREEN}Processor image pushed${NC}"

# Build query with explicit platform for Lambda
echo "Building query image..."
cd ../query
docker build \
  --platform linux/amd64 \
  --no-cache \
  -t ${ECR_REPO_QUERY}:latest \
  .
docker tag ${ECR_REPO_QUERY}:latest \
  ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_QUERY}:latest
docker push ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_QUERY}:latest
echo -e "${GREEN}Query image pushed${NC}"

cd ..

# Verify images in ECR
echo -e "\n${BLUE}Verificando imágenes en ECR...${NC}"
aws ecr describe-images \
  --repository-name ${ECR_REPO_PROCESSOR} \
  --region ${AWS_REGION} \
  --query 'imageDetails[0].[imageTags[0],imageSizeInBytes,imagePushedAt]' \
  --output table 2>/dev/null || echo -e "${YELLOW}No se pudo verificar processor image${NC}"

aws ecr describe-images \
  --repository-name ${ECR_REPO_QUERY} \
  --region ${AWS_REGION} \
  --query 'imageDetails[0].[imageTags[0],imageSizeInBytes,imagePushedAt]' \
  --output table 2>/dev/null || echo -e "${YELLOW}No se pudo verificar query image${NC}"

# ============================================================
# PASO 4: CREAR VPC SECURITY GROUP
# ============================================================
echo -e "\n${BLUE}PASO 4: Configurando networking...${NC}"

# Get default VPC
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" \
  --query 'Vpcs[0].VpcId' --output text --region ${AWS_REGION})

# Create or get security group
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${PROJECT_NAME}-aurora-sg" \
  --query 'SecurityGroups[0].GroupId' \
  --output text --region ${AWS_REGION} 2>/dev/null)

if [ "$SG_ID" = "" ] || [ "$SG_ID" = "None" ]; then
  SG_ID=$(aws ec2 create-security-group \
    --group-name ${PROJECT_NAME}-aurora-sg \
    --description "Security group for RAG database" \
    --vpc-id ${VPC_ID} \
    --region ${AWS_REGION} \
    --query 'GroupId' --output text)
  echo -e "${GREEN}Security group creado: ${SG_ID}${NC}"
else
  echo -e "${YELLOW}Security group ya existe: ${SG_ID}${NC}"
fi

# Allow inbound Postgres
aws ec2 authorize-security-group-ingress \
  --group-id ${SG_ID} \
  --protocol tcp \
  --port 5432 \
  --source-group ${SG_ID} \
  --region ${AWS_REGION} 2>/dev/null || echo -e "${YELLOW}Ingress rule ya existe${NC}"

# Get subnets
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[*].SubnetId' \
  --output text --region ${AWS_REGION})

SUBNET_ARRAY=($SUBNET_IDS)

# Create DB subnet group
aws rds create-db-subnet-group \
  --db-subnet-group-name ${PROJECT_NAME}-subnet-group \
  --db-subnet-group-description "Subnet group for RAG" \
  --subnet-ids ${SUBNET_IDS} \
  --region ${AWS_REGION} 2>/dev/null && echo "Subnet group creado" || echo -e "${YELLOW}Subnet group ya existe${NC}"

# ============================================================
# CREAR VPC ENDPOINTS (S3 y Bedrock)
# ============================================================
echo -e "\n${BLUE}Configurando VPC Endpoints...${NC}"

# Get Route Tables
ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'RouteTables[*].RouteTableId' \
  --output text --region ${AWS_REGION})

# VPC Endpoint para S3 (Gateway - GRATIS)
echo "→ VPC Endpoint para S3..."
S3_ENDPOINT=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=com.amazonaws.${AWS_REGION}.s3" \
  --query 'VpcEndpoints[0].VpcEndpointId' \
  --output text --region ${AWS_REGION} 2>/dev/null)

if [ "$S3_ENDPOINT" = "" ] || [ "$S3_ENDPOINT" = "None" ]; then
    aws ec2 create-vpc-endpoint \
      --vpc-id ${VPC_ID} \
      --service-name com.amazonaws.${AWS_REGION}.s3 \
      --route-table-ids ${ROUTE_TABLE_IDS} \
      --region ${AWS_REGION} >/dev/null 2>&1 && \
      echo -e "${GREEN}  ✓ S3 VPC Endpoint creado${NC}" || \
      echo -e "${YELLOW}  ⚠️  Error creando S3 endpoint${NC}"
else
    echo -e "${GREEN}  ✓ S3 VPC Endpoint ya existe${NC}"
fi

# VPC Endpoint para Bedrock Runtime (Interface - ~$7/mes)
echo "→ VPC Endpoint para Bedrock Runtime..."

# Asegurar que SG permite HTTPS
aws ec2 authorize-security-group-ingress \
  --group-id ${SG_ID} \
  --protocol tcp \
  --port 443 \
  --source-group ${SG_ID} \
  --region ${AWS_REGION} 2>/dev/null || true

BEDROCK_ENDPOINT=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=com.amazonaws.${AWS_REGION}.bedrock-runtime" \
  --query 'VpcEndpoints[0].VpcEndpointId' \
  --output text --region ${AWS_REGION} 2>/dev/null)

if [ "$BEDROCK_ENDPOINT" = "" ] || [ "$BEDROCK_ENDPOINT" = "None" ]; then
    aws ec2 create-vpc-endpoint \
      --vpc-id ${VPC_ID} \
      --vpc-endpoint-type Interface \
      --service-name com.amazonaws.${AWS_REGION}.bedrock-runtime \
      --subnet-ids ${SUBNET_IDS} \
      --security-group-ids ${SG_ID} \
      --region ${AWS_REGION} >/dev/null 2>&1 && \
      echo -e "${GREEN}  ✓ Bedrock VPC Endpoint creado${NC}" || \
      echo -e "${YELLOW}  ⚠️  Error creando Bedrock endpoint${NC}"
else
    echo -e "${GREEN}  ✓ Bedrock VPC Endpoint ya existe${NC}"
fi

# ============================================================
# PASO 5: CREAR RDS POSTGRES
# ============================================================
echo -e "\n${BLUE}PASO 5: Verificando RDS Postgres...${NC}"

EXISTING_INSTANCE=$(aws rds describe-db-instances \
  --db-instance-identifier ${DB_INSTANCE_NAME} \
  --query 'DBInstances[0].DBInstanceIdentifier' \
  --output text --region ${AWS_REGION} 2>/dev/null || echo "")

if [ "$EXISTING_INSTANCE" = "${DB_INSTANCE_NAME}" ]; then
  echo -e "${YELLOW}RDS instance ya existe, reutilizando${NC}"
  DB_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier ${DB_INSTANCE_NAME} \
    --query 'DBInstances[0].Endpoint.Address' \
    --output text --region ${AWS_REGION})
else
  echo "Creando RDS Postgres instance..."
  aws rds create-db-instance \
    --db-instance-identifier ${DB_INSTANCE_NAME} \
    --db-instance-class db.t3.micro \
    --engine postgres \
    --engine-version 15.15 \
    --master-username ${DB_USER} \
    --master-user-password ${DB_PASSWORD} \
    --db-name ${DB_NAME} \
    --allocated-storage 20 \
    --db-subnet-group-name ${PROJECT_NAME}-subnet-group \
    --vpc-security-group-ids ${SG_ID} \
    --backup-retention-period 0 \
    --no-multi-az \
    --region ${AWS_REGION}

  echo "Esperando a que RDS instance esté disponible (5-10 minutos)..."
  aws rds wait db-instance-available \
    --db-instance-identifier ${DB_INSTANCE_NAME} \
    --region ${AWS_REGION}

  DB_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier ${DB_INSTANCE_NAME} \
    --query 'DBInstances[0].Endpoint.Address' \
    --output text --region ${AWS_REGION})

  echo -e "${GREEN}RDS Postgres creado${NC}"
fi

echo -e "${GREEN}DB Endpoint: ${DB_ENDPOINT}${NC}"

# ============================================================
# PASO 6: Schema init (se ejecuta en PASO 6b, tras crear las Lambdas)
# ============================================================
SCHEMA_EXECUTED=false
if [ ! -f "schema.sql" ]; then
    echo -e "\n${YELLOW}⚠️  schema.sql no encontrado - ejecuta el schema manualmente después${NC}"
fi

# ============================================================
# PASO 7: CREAR ROLES IAM
# ============================================================
echo -e "\n${BLUE}PASO 7: Verificando roles IAM...${NC}"

cat > lambda-role-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name ${PROJECT_NAME}-lambda-role \
  --assume-role-policy-document file://lambda-role-trust.json \
  2>/dev/null && echo "IAM role creado" || echo -e "${YELLOW}IAM role ya existe${NC}"

aws iam attach-role-policy \
  --role-name ${PROJECT_NAME}-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true

aws iam attach-role-policy \
  --role-name ${PROJECT_NAME}-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess 2>/dev/null || true

aws iam attach-role-policy \
  --role-name ${PROJECT_NAME}-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonBedrockFullAccess 2>/dev/null || true

cat > lambda-vpc-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses"
    ],
    "Resource": "*"
  }]
}
EOF

aws iam put-role-policy \
  --role-name ${PROJECT_NAME}-lambda-role \
  --policy-name LambdaVPCAccess \
  --policy-document file://lambda-vpc-policy.json 2>/dev/null || true

echo "Esperando 10s para propagación de roles..."
sleep 10

# ============================================================
# PASO 8: CREAR LAMBDA PROCESSOR
# ============================================================
echo -e "\n${BLUE}PASO 8: Creando/Actualizando Lambda processor...${NC}"

EXISTING_LAMBDA=$(aws lambda get-function \
  --function-name ${LAMBDA_PROCESSOR} \
  --region ${AWS_REGION} 2>/dev/null)

if [ $? -eq 0 ]; then
  echo -e "${YELLOW}Lambda processor ya existe, actualizando código...${NC}"
  aws lambda update-function-code \
    --function-name ${LAMBDA_PROCESSOR} \
    --image-uri ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_PROCESSOR}:latest \
    --region ${AWS_REGION}
  
  sleep 5
  
  aws lambda update-function-configuration \
    --function-name ${LAMBDA_PROCESSOR} \
    --environment "Variables={DB_HOST=${DB_ENDPOINT},DB_NAME=${DB_NAME},DB_USER=${DB_USER},DB_PASSWORD=${DB_PASSWORD}}" \
    --region ${AWS_REGION}
else
  echo "Creando Lambda processor..."
  aws lambda create-function \
    --function-name ${LAMBDA_PROCESSOR} \
    --package-type Image \
    --code ImageUri=${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_PROCESSOR}:latest \
    --role arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PROJECT_NAME}-lambda-role \
    --timeout 900 \
    --memory-size 1024 \
    --vpc-config SubnetIds=${SUBNET_ARRAY[0]},${SUBNET_ARRAY[1]},SecurityGroupIds=${SG_ID} \
    --environment "Variables={DB_HOST=${DB_ENDPOINT},DB_NAME=${DB_NAME},DB_USER=${DB_USER},DB_PASSWORD=${DB_PASSWORD}}" \
    --region ${AWS_REGION}
fi

echo -e "${GREEN}Lambda processor configurada${NC}"

# ============================================================
# PASO 6b: INICIALIZAR SCHEMA (acceso temporal para ejecutar desde Docker local)
# ============================================================
echo -e "\n${BLUE}PASO 6b: Inicializando schema de base de datos...${NC}"
echo "   → Habilitando acceso temporal a RDS para ejecutar schema"

if [ ! -f "schema.sql" ]; then
    echo -e "${YELLOW}⚠️  schema.sql no encontrado, saltando schema init${NC}"
elif [ "$SCHEMA_EXECUTED" = false ]; then

    # Verificar que Docker esté disponible
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}   ✗ Docker no encontrado. Instala Docker Desktop.${NC}"
    elif ! docker info >/dev/null 2>&1; then
        echo -e "${RED}   ✗ Docker no está corriendo. Inicia Docker Desktop.${NC}"
    else
        echo "   Paso 1: Obteniendo tu IP pública..."
        MY_IP=$(curl -s https://checkip.amazonaws.com 2>/dev/null | tr -d '\r\n')
        
        if [ -z "$MY_IP" ]; then
            echo -e "${YELLOW}   ⚠️  No se pudo obtener IP pública, usando 0.0.0.0/0 (menos seguro)${NC}"
            MY_IP="0.0.0.0"
        else
            echo "   Tu IP: ${MY_IP}"
        fi
        
        echo "   Paso 2: Habilitando acceso público temporal en RDS..."
        aws rds modify-db-instance \
          --db-instance-identifier ${DB_INSTANCE_NAME} \
          --publicly-accessible \
          --apply-immediately \
          --region ${AWS_REGION} >/dev/null 2>&1
        
        echo "   Paso 3: Añadiendo regla temporal al Security Group (puerto 5432 desde ${MY_IP})..."
        TEMP_RULE_ID="temp-schema-init-$$"
        aws ec2 authorize-security-group-ingress \
          --group-id ${SG_ID} \
          --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,IpRanges=[{CidrIp=${MY_IP}/32,Description=${TEMP_RULE_ID}}]" \
          --region ${AWS_REGION} 2>/dev/null || echo "   (Regla puede ya existir)"
        
        echo "   Paso 4: Esperando que RDS esté accesible públicamente..."
        echo "   (Esto puede tardar 1-2 minutos...)"
        
        # Esperar hasta 3 minutos
        WAIT_COUNT=0
        MAX_WAIT=36  # 36 * 5s = 3 minutos
        RDS_READY=false
        
        while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
            RDS_STATUS=$(aws rds describe-db-instances \
              --db-instance-identifier ${DB_INSTANCE_NAME} \
              --region ${AWS_REGION} \
              --query 'DBInstances[0].[DBInstanceStatus,PubliclyAccessible]' \
              --output text 2>/dev/null)
            
            DB_STATUS=$(echo "$RDS_STATUS" | awk '{print $1}')
            IS_PUBLIC=$(echo "$RDS_STATUS" | awk '{print $2}')
            
            if [ "$DB_STATUS" = "available" ] && [ "$IS_PUBLIC" = "True" ]; then
                echo "   ✓ RDS accesible"
                RDS_READY=true
                break
            fi
            
            sleep 5
            WAIT_COUNT=$((WAIT_COUNT + 1))
        done
        
        if [ "$RDS_READY" = false ]; then
            echo -e "${YELLOW}   ⚠️  Timeout esperando RDS. Continuando de todas formas...${NC}"
        fi
        
        # Espera adicional de seguridad
        sleep 10
        
        echo "   Paso 5: Ejecutando schema.sql con Docker..."
        docker pull postgres:15 >/dev/null 2>&1
        
        SCHEMA_OUTPUT=$(cat schema.sql | docker run -i --rm \
          -e PGPASSWORD=${DB_PASSWORD} \
          postgres:15 \
          psql -h ${DB_ENDPOINT} -U ${DB_USER} -d ${DB_NAME} -v ON_ERROR_STOP=1 2>&1)
        
        SCHEMA_EXIT=$?
        
        if [ $SCHEMA_EXIT -eq 0 ] && ! echo "$SCHEMA_OUTPUT" | grep -qi "ERROR\|FATAL\|Connection refused"; then
            echo -e "${GREEN}   ✓ Schema ejecutado correctamente${NC}"
            SCHEMA_EXECUTED=true
            
            # Verificar tablas creadas
            TABLES=$(echo "\dt" | docker run -i --rm \
              -e PGPASSWORD=${DB_PASSWORD} \
              postgres:15 \
              psql -h ${DB_ENDPOINT} -U ${DB_USER} -d ${DB_NAME} -t 2>&1 | grep -c "table" || echo "0")
            [ "$TABLES" -gt 0 ] && echo "   Tablas creadas: ${TABLES}"
        else
            echo -e "${RED}   ✗ Error ejecutando schema:${NC}"
            echo "$SCHEMA_OUTPUT" | grep -i "ERROR\|FATAL" | head -3 | sed 's/^/   /'
        fi
        
        echo "   Paso 6: Restaurando configuración de seguridad..."
        
        # Eliminar regla temporal del Security Group
        echo "   → Eliminando regla temporal del firewall..."
        aws ec2 revoke-security-group-ingress \
          --group-id ${SG_ID} \
          --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,IpRanges=[{CidrIp=${MY_IP}/32}]" \
          --region ${AWS_REGION} 2>/dev/null || echo "   (Regla no encontrada)"
        
        # Volver a dejar RDS privado
        echo "   → Deshabilitando acceso público en RDS..."
        aws rds modify-db-instance \
          --db-instance-identifier ${DB_INSTANCE_NAME} \
          --no-publicly-accessible \
          --apply-immediately \
          --region ${AWS_REGION} >/dev/null 2>&1
        
        echo -e "${GREEN}   ✓ RDS vuelto a privado${NC}"
        
        if [ "$SCHEMA_EXECUTED" = false ]; then
            echo ""
            echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${RED}✗ SCHEMA NO SE PUDO EJECUTAR${NC}"
            echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo "Solución alternativa:"
            echo ""
            echo "Ejecuta manualmente en PowerShell:"
            echo "  Get-Content schema.sql | docker run -i --rm \"
            echo "    -e PGPASSWORD=${DB_PASSWORD} postgres:15 \"
            echo "    psql -h ${DB_ENDPOINT} -U ${DB_USER} -d ${DB_NAME}"
            echo ""
            echo "Si falla con 'Connection refused', ejecuta estos comandos AWS CLI:"
            echo "  aws rds modify-db-instance --db-instance-identifier ${DB_INSTANCE_NAME} --publicly-accessible --apply-immediately"
            echo "  aws ec2 authorize-security-group-ingress --group-id ${SG_ID} --protocol tcp --port 5432 --cidr 0.0.0.0/0"
            echo ""
            echo "Luego ejecuta el schema, y cierra el acceso:"
            echo "  aws rds modify-db-instance --db-instance-identifier ${DB_INSTANCE_NAME} --no-publicly-accessible --apply-immediately"
            echo "  aws ec2 revoke-security-group-ingress --group-id ${SG_ID} --protocol tcp --port 5432 --cidr 0.0.0.0/0"
            echo ""
            read -t 30 -p "Presiona Enter para continuar..." 2>/dev/null || echo ""
        fi
    fi
fi
export SCHEMA_STATUS=$SCHEMA_EXECUTED




# ============================================================
# PASO 9: CREAR LAMBDA QUERY
# ============================================================
echo -e "\n${BLUE}PASO 9: Creando/Actualizando Lambda query...${NC}"

EXISTING_QUERY=$(aws lambda get-function \
  --function-name ${LAMBDA_QUERY} \
  --region ${AWS_REGION} 2>/dev/null)

if [ $? -eq 0 ]; then
  echo -e "${YELLOW}Lambda query ya existe, actualizando código...${NC}"
  aws lambda update-function-code \
    --function-name ${LAMBDA_QUERY} \
    --image-uri ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_QUERY}:latest \
    --region ${AWS_REGION}
  
  sleep 5
  
  aws lambda update-function-configuration \
    --function-name ${LAMBDA_QUERY} \
    --environment "Variables={DB_HOST=${DB_ENDPOINT},DB_NAME=${DB_NAME},DB_USER=${DB_USER},DB_PASSWORD=${DB_PASSWORD}}" \
    --region ${AWS_REGION}
else
  echo "Creando Lambda query..."
  aws lambda create-function \
    --function-name ${LAMBDA_QUERY} \
    --package-type Image \
    --code ImageUri=${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_QUERY}:latest \
    --role arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PROJECT_NAME}-lambda-role \
    --timeout 300 \
    --memory-size 512 \
    --vpc-config SubnetIds=${SUBNET_ARRAY[0]},${SUBNET_ARRAY[1]},SecurityGroupIds=${SG_ID} \
    --environment "Variables={DB_HOST=${DB_ENDPOINT},DB_NAME=${DB_NAME},DB_USER=${DB_USER},DB_PASSWORD=${DB_PASSWORD}}" \
    --region ${AWS_REGION}
fi

echo -e "${GREEN}Lambda query configurada${NC}"

# ============================================================
# ESPERAR A QUE LAMBDAS ESTEN ACTIVAS
# ============================================================
echo -e "\n${BLUE}Esperando a que las Lambdas estén activas...${NC}"

echo "Esperando Lambda processor..."
aws lambda wait function-active-v2 \
  --function-name ${LAMBDA_PROCESSOR} \
  --region ${AWS_REGION} 2>/dev/null && \
  echo -e "${GREEN}✓ Processor Lambda activa${NC}" || \
  echo -e "${YELLOW}⚠️  Processor Lambda aún inicializando (continuando)${NC}"

echo "Esperando Lambda query..."
aws lambda wait function-active-v2 \
  --function-name ${LAMBDA_QUERY} \
  --region ${AWS_REGION} 2>/dev/null && \
  echo -e "${GREEN}✓ Query Lambda activa${NC}" || \
  echo -e "${YELLOW}⚠️  Query Lambda aún inicializando (continuando)${NC}"

# Additional wait to ensure Lambda is fully ready
echo "Esperando 10s adicionales para asegurar que las Lambdas estén completamente listas..."
sleep 10

# ============================================================
# PASO 10: CONFIGURAR S3 TRIGGER
# ============================================================
echo -e "\n${BLUE}PASO 10: Configurando S3 trigger...${NC}"

aws lambda add-permission \
  --function-name ${LAMBDA_PROCESSOR} \
  --statement-id s3-trigger \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn arn:aws:s3:::${BUCKET_NAME} \
  --region ${AWS_REGION} 2>/dev/null || echo -e "${YELLOW}Permiso S3 ya existe${NC}"

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

# Try to configure S3 trigger with retry logic
MAX_RETRIES=3
RETRY_COUNT=0
S3_CONFIGURED=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$S3_CONFIGURED" = false ]; do
  if [ $RETRY_COUNT -gt 0 ]; then
    echo "Reintento $RETRY_COUNT de $MAX_RETRIES en 10 segundos..."
    sleep 10
  fi
  
  if aws s3api put-bucket-notification-configuration \
    --bucket ${BUCKET_NAME} \
    --notification-configuration file://s3-notification.json 2>/dev/null; then
    S3_CONFIGURED=true
    echo -e "${GREEN}S3 trigger configurado${NC}"
  else
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
      echo -e "${YELLOW}Error configurando S3 trigger, reintentando...${NC}"
    fi
  fi
done

if [ "$S3_CONFIGURED" = false ]; then
  echo -e "${YELLOW}⚠️  No se pudo configurar S3 trigger automáticamente.${NC}"
  echo "Ejecuta manualmente después:"
  echo "  aws s3api put-bucket-notification-configuration --bucket ${BUCKET_NAME} --notification-configuration file://s3-notification.json"
fi

# ============================================================
# PASO 11: CREAR FUNCTION URL
# ============================================================
echo -e "\n${BLUE}PASO 11: Configurando Function URL...${NC}"

FUNCTION_URL=$(aws lambda get-function-url-config \
  --function-name ${LAMBDA_QUERY} \
  --region ${AWS_REGION} \
  --query 'FunctionUrl' \
  --output text 2>/dev/null)

if [ "$FUNCTION_URL" = "" ] || [ "$FUNCTION_URL" = "None" ]; then
  FUNCTION_URL=$(aws lambda create-function-url-config \
    --function-name ${LAMBDA_QUERY} \
    --auth-type NONE \
    --cors AllowOrigins="*",AllowMethods="POST",AllowHeaders="*" \
    --region ${AWS_REGION} \
    --query 'FunctionUrl' \
    --output text)
  echo -e "${GREEN}Function URL creada${NC}"
else
  echo -e "${YELLOW}Function URL ya existe${NC}"
fi

aws lambda add-permission \
  --function-name ${LAMBDA_QUERY} \
  --statement-id FunctionURLAllowPublicAccess \
  --action lambda:InvokeFunctionUrl \
  --principal "*" \
  --function-url-auth-type NONE \
  --region ${AWS_REGION} 2>/dev/null || echo -e "${YELLOW}Permission ya existe${NC}"

echo -e "${GREEN}Function URL: ${FUNCTION_URL}${NC}"

# ============================================================
# RESUMEN FINAL
# ============================================================
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN} DESPLIEGUE COMPLETADO${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Verificar estado de componentes
PROCESSOR_STATE=$(aws lambda get-function \
  --function-name ${LAMBDA_PROCESSOR} \
  --region ${AWS_REGION} \
  --query 'Configuration.State' \
  --output text 2>/dev/null || echo "UNKNOWN")

QUERY_STATE=$(aws lambda get-function \
  --function-name ${LAMBDA_QUERY} \
  --region ${AWS_REGION} \
  --query 'Configuration.State' \
  --output text 2>/dev/null || echo "UNKNOWN")

S3_TRIGGER=$(aws s3api get-bucket-notification-configuration \
  --bucket ${BUCKET_NAME} \
  --query 'LambdaFunctionConfigurations[0].LambdaFunctionArn' \
  --output text 2>/dev/null || echo "NOT_CONFIGURED")

# Mostrar información de conexión
echo -e "${BLUE}INFORMACIÓN DE LA BASE DE DATOS:${NC}"
echo "  Host:     ${DB_ENDPOINT}"
echo "  Database: ${DB_NAME}"
echo "  User:     ${DB_USER}"
echo "  Password: ${DB_PASSWORD}"
echo ""

echo -e "${BLUE}LAMBDAS:${NC}"
echo "  Processor: ${LAMBDA_PROCESSOR}"
echo "  Query:     ${LAMBDA_QUERY}"
echo "  API URL:   ${FUNCTION_URL}"
echo ""

echo -e "${BLUE}ESTADO DE COMPONENTES:${NC}"

# Lambda Status
if [ "$PROCESSOR_STATE" = "Active" ]; then
  echo -e "  Processor Lambda: ${GREEN}✓ Active${NC}"
else
  echo -e "  Processor Lambda: ${YELLOW}⚠️  ${PROCESSOR_STATE}${NC}"
fi

if [ "$QUERY_STATE" = "Active" ]; then
  echo -e "  Query Lambda:     ${GREEN}✓ Active${NC}"
else
  echo -e "  Query Lambda:     ${YELLOW}⚠️  ${QUERY_STATE}${NC}"
fi

# S3 Trigger Status
if [ "$S3_TRIGGER" != "NOT_CONFIGURED" ]; then
  echo -e "  S3 Trigger:       ${GREEN}✓ Configured${NC}"
else
  echo -e "  S3 Trigger:       ${YELLOW}⚠️  Not configured${NC}"
fi

# Schema Status
if [ "$SCHEMA_STATUS" = "true" ]; then
  echo -e "  Database Schema:  ${GREEN}✓ Initialized${NC}"
else
  echo -e "  Database Schema:  ${RED}✗ NOT INITIALIZED${NC}"
  echo -e "                    ${YELLOW}Run: ./init_schema_via_lambda.sh${NC}"
fi

echo ""

# Determinar si el sistema está listo
ALL_READY=true
if [ "$PROCESSOR_STATE" != "Active" ] || [ "$QUERY_STATE" != "Active" ]; then
  ALL_READY=false
fi
if [ "$S3_TRIGGER" = "NOT_CONFIGURED" ]; then
  ALL_READY=false
fi
if [ "$SCHEMA_STATUS" != "true" ]; then
  ALL_READY=false
fi

if [ "$ALL_READY" = true ]; then
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}✓ SISTEMA COMPLETAMENTE FUNCIONAL${NC}"
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "${BLUE}PROBAR EL SISTEMA:${NC}"
  echo ""
  echo "1. Subir un documento:"
  echo "   aws s3 cp documento.pdf s3://${BUCKET_NAME}/docs/documento.pdf"
  echo ""
  echo "2. Hacer una pregunta:"
  echo "   curl -X POST ${FUNCTION_URL} \\"
  echo "     -H 'Content-Type: application/json' \\"
  echo "     -d '{\"question\": \"¿De qué trata el documento?\"}'"
  echo ""
else
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${YELLOW}⚠️  ACCIONES PENDIENTES${NC}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  
  # Schema no inicializado - CRÍTICO
  if [ "$SCHEMA_STATUS" != "true" ]; then
    echo -e "${RED}✗ DATABASE SCHEMA NO INICIALIZADO (CRÍTICO)${NC}"
    echo ""
    echo "El schema crea las tablas necesarias en PostgreSQL."
    echo "Sin el schema, el sistema NO puede almacenar documentos."
    echo ""
    
    if [ "$DETECTED_OS" = "windows" ]; then
      echo "EJECUTA EN POWERSHELL:"
      echo "  Get-Content schema.sql | docker run -i --rm \\"
      echo "    -e PGPASSWORD=${DB_PASSWORD} postgres:15 \\"
      echo "    psql -h ${DB_ENDPOINT} -U ${DB_USER} -d ${DB_NAME}"
    else
      echo "EJECUTA:"
      if command -v docker &> /dev/null; then
        echo "  cat schema.sql | docker run -i --rm -e PGPASSWORD=${DB_PASSWORD} postgres:15 \\"
        echo "    psql -h ${DB_ENDPOINT} -U ${DB_USER} -d ${DB_NAME}"
      else
        echo "  PGPASSWORD=${DB_PASSWORD} psql -h ${DB_ENDPOINT} -U ${DB_USER} -d ${DB_NAME} -f schema.sql"
      fi
    fi
    echo ""
  fi
  
  # Lambdas no activas
  if [ "$PROCESSOR_STATE" != "Active" ] || [ "$QUERY_STATE" != "Active" ]; then
    echo -e "${YELLOW}⚠️  Lambdas aún inicializando (espera 2-3 minutos)${NC}"
    echo ""
  fi
  
  # S3 Trigger no configurado
  if [ "$S3_TRIGGER" = "NOT_CONFIGURED" ]; then
    echo -e "${YELLOW}⚠️  S3 Trigger no configurado${NC}"
    echo "Re-ejecuta el script en 2 minutos: ./deploy_rag.sh"
    echo ""
  fi
fi

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
DB_INSTANCE_NAME=${DB_INSTANCE_NAME}
EOF

echo -e "${GREEN}Configuración guardada en .rag-deployment-config${NC}"
