#!/bin/bash
set +e

# ============================================================
# CONFIGURACION
# ============================================================
export AWS_REGION="eu-west-1"
export PROJECT_NAME="rag-system-alejandrogolfe"
export BUCKET_NAME="${PROJECT_NAME}-docs"
export ECR_REPO_PROCESSOR="${PROJECT_NAME}-processor"
export LAMBDA_PROCESSOR="${PROJECT_NAME}-processor"
export EC2_NAME="${PROJECT_NAME}-streamlit"
export EC2_SG_NAME="${PROJECT_NAME}-streamlit-sg"
export EC2_INSTANCE_PROFILE="${PROJECT_NAME}-ec2-profile"
export EC2_ROLE_NAME="${PROJECT_NAME}-ec2-role"
export DB_NAME="ragdb"
export DB_USER="ragadmin"
export DB_INSTANCE_NAME="${PROJECT_NAME}-postgres"

if [ -f .rag-deployment-config ]; then
    source .rag-deployment-config
    echo "Loaded existing config from .rag-deployment-config"
else
    export DB_PASSWORD="RagSecurePass$(date +%s)"
fi

if [ -z "$OPENAI_API_KEY" ]; then
    echo "ERROR: OPENAI_API_KEY no está definida."
    echo "Ejecuta: export OPENAI_API_KEY='sk-...'"
    exit 1
fi

GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE} RAG SYSTEM DEPLOYMENT${NC}"
echo -e "${BLUE}========================================${NC}"

DETECTED_OS="unknown"
if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "win32" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
    DETECTED_OS="windows"; echo -e "${YELLOW}⚠️  Detected: Windows/Git Bash${NC}"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    DETECTED_OS="macos"; echo -e "${GREEN}Detected: macOS${NC}"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    DETECTED_OS="linux"; echo -e "${GREEN}Detected: Linux${NC}"
fi

export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo -e "${GREEN}Account ID: ${AWS_ACCOUNT_ID}${NC}"

# ============================================================
# PASO 1: BUCKET S3
# ============================================================
echo -e "\n${BLUE}PASO 1: Verificando bucket S3...${NC}"
if aws s3 ls s3://${BUCKET_NAME} --region ${AWS_REGION} 2>/dev/null; then
    echo -e "${YELLOW}Bucket ya existe${NC}"
else
    aws s3 mb s3://${BUCKET_NAME} --region ${AWS_REGION}
    echo -e "${GREEN}Bucket creado: ${BUCKET_NAME}${NC}"
fi
aws s3api put-object --bucket ${BUCKET_NAME} --key docs/ --region ${AWS_REGION} 2>/dev/null || true

# ============================================================
# PASO 2: ECR REPOSITORY
# ============================================================
echo -e "\n${BLUE}PASO 2: Verificando repositorio ECR...${NC}"
aws ecr create-repository \
  --repository-name ${ECR_REPO_PROCESSOR} \
  --region ${AWS_REGION} 2>/dev/null && echo "Repo creado" || echo -e "${YELLOW}Repo ya existe${NC}"

# ============================================================
# PASO 3: BUILD Y PUSH IMAGEN DOCKER DEL PROCESSOR
# ============================================================
echo -e "\n${BLUE}PASO 3: Building imagen Docker del processor...${NC}"

export DOCKER_BUILDKIT=0

aws ecr get-login-password --region ${AWS_REGION} | \
  docker login --username AWS --password-stdin \
  ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

# Copiar archivos RAG al contexto de build del processor
cp pipeline.py processor/pipeline.py
cp config.py   processor/config.py
cp setup.yaml  processor/setup.yaml

cd processor
docker build --platform linux/amd64 --no-cache -t ${ECR_REPO_PROCESSOR}:latest .
docker tag ${ECR_REPO_PROCESSOR}:latest \
  ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_PROCESSOR}:latest
docker push ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_PROCESSOR}:latest
echo -e "${GREEN}Processor image pushed${NC}"
cd ..

# Limpiar copias temporales del contexto de build
rm -f processor/pipeline.py processor/config.py processor/setup.yaml

aws ecr describe-images \
  --repository-name ${ECR_REPO_PROCESSOR} --region ${AWS_REGION} \
  --query 'imageDetails[0].[imageTags[0],imageSizeInBytes,imagePushedAt]' \
  --output table 2>/dev/null || echo -e "${YELLOW}No se pudo verificar imagen${NC}"

# ============================================================
# PASO 4: NETWORKING
# ============================================================
echo -e "\n${BLUE}PASO 4: Configurando networking...${NC}"

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" \
  --query 'Vpcs[0].VpcId' --output text --region ${AWS_REGION})

SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${PROJECT_NAME}-aurora-sg" \
  --query 'SecurityGroups[0].GroupId' --output text --region ${AWS_REGION} 2>/dev/null)

if [ "$SG_ID" = "" ] || [ "$SG_ID" = "None" ]; then
  SG_ID=$(aws ec2 create-security-group \
    --group-name ${PROJECT_NAME}-aurora-sg \
    --description "Security group for RAG database" \
    --vpc-id ${VPC_ID} --region ${AWS_REGION} --query 'GroupId' --output text)
  echo -e "${GREEN}Security group DB creado: ${SG_ID}${NC}"
else
  echo -e "${YELLOW}Security group DB ya existe: ${SG_ID}${NC}"
fi

aws ec2 authorize-security-group-ingress \
  --group-id ${SG_ID} --protocol tcp --port 5432 --source-group ${SG_ID} \
  --region ${AWS_REGION} 2>/dev/null || true

SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[*].SubnetId' --output text --region ${AWS_REGION})
SUBNET_ARRAY=($SUBNET_IDS)

aws rds create-db-subnet-group \
  --db-subnet-group-name ${PROJECT_NAME}-subnet-group \
  --db-subnet-group-description "Subnet group for RAG" \
  --subnet-ids ${SUBNET_IDS} --region ${AWS_REGION} \
  2>/dev/null && echo "Subnet group creado" || echo -e "${YELLOW}Subnet group ya existe${NC}"

# VPC Endpoint S3 (gratuito)
ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'RouteTables[*].RouteTableId' --output text --region ${AWS_REGION})
S3_ENDPOINT=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=com.amazonaws.${AWS_REGION}.s3" \
  --query 'VpcEndpoints[0].VpcEndpointId' --output text --region ${AWS_REGION} 2>/dev/null)
if [ "$S3_ENDPOINT" = "" ] || [ "$S3_ENDPOINT" = "None" ]; then
    aws ec2 create-vpc-endpoint \
      --vpc-id ${VPC_ID} --service-name com.amazonaws.${AWS_REGION}.s3 \
      --route-table-ids ${ROUTE_TABLE_IDS} --region ${AWS_REGION} >/dev/null 2>&1 && \
      echo -e "${GREEN}✓ S3 VPC Endpoint creado${NC}" || echo -e "${YELLOW}⚠️  Error S3 endpoint${NC}"
else
    echo -e "${GREEN}✓ S3 VPC Endpoint ya existe${NC}"
fi

# ============================================================
# PASO 5: RDS POSTGRES
# ============================================================
echo -e "\n${BLUE}PASO 5: Verificando RDS Postgres...${NC}"

EXISTING_INSTANCE=$(aws rds describe-db-instances \
  --db-instance-identifier ${DB_INSTANCE_NAME} \
  --query 'DBInstances[0].DBInstanceIdentifier' \
  --output text --region ${AWS_REGION} 2>/dev/null || echo "")

if [ "$EXISTING_INSTANCE" = "${DB_INSTANCE_NAME}" ]; then
  echo -e "${YELLOW}RDS ya existe, reutilizando${NC}"
  DB_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier ${DB_INSTANCE_NAME} \
    --query 'DBInstances[0].Endpoint.Address' \
    --output text --region ${AWS_REGION})
else
  aws rds create-db-instance \
    --db-instance-identifier ${DB_INSTANCE_NAME} \
    --db-instance-class db.t3.micro --engine postgres --engine-version 15.15 \
    --master-username ${DB_USER} --master-user-password ${DB_PASSWORD} \
    --db-name ${DB_NAME} --allocated-storage 20 \
    --db-subnet-group-name ${PROJECT_NAME}-subnet-group \
    --vpc-security-group-ids ${SG_ID} \
    --backup-retention-period 0 --no-multi-az --region ${AWS_REGION}
  echo "Esperando RDS (5-10 minutos)..."
  aws rds wait db-instance-available --db-instance-identifier ${DB_INSTANCE_NAME} --region ${AWS_REGION}
  DB_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier ${DB_INSTANCE_NAME} \
    --query 'DBInstances[0].Endpoint.Address' --output text --region ${AWS_REGION})
  echo -e "${GREEN}RDS creado: ${DB_ENDPOINT}${NC}"
fi
echo -e "${GREEN}DB Endpoint: ${DB_ENDPOINT}${NC}"

# ============================================================
# PASO 6: SCHEMA (langchain PGVector)
# ============================================================
echo -e "\n${BLUE}PASO 6: Inicializando schema...${NC}"
SCHEMA_EXECUTED=false

if [ -f "schema.sql" ] && command -v docker &> /dev/null && docker info >/dev/null 2>&1; then
    MY_IP=$(curl -s https://checkip.amazonaws.com 2>/dev/null | tr -d '\r\n')
    [ -z "$MY_IP" ] && MY_IP="0.0.0.0"

    aws rds modify-db-instance --db-instance-identifier ${DB_INSTANCE_NAME} \
      --publicly-accessible --apply-immediately --region ${AWS_REGION} >/dev/null 2>&1
    aws ec2 authorize-security-group-ingress --group-id ${SG_ID} \
      --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,IpRanges=[{CidrIp=${MY_IP}/32}]" \
      --region ${AWS_REGION} 2>/dev/null || true

    echo "Esperando acceso público RDS..."
    WAIT_COUNT=0
    while [ $WAIT_COUNT -lt 36 ]; do
        RDS_STATUS=$(aws rds describe-db-instances --db-instance-identifier ${DB_INSTANCE_NAME} \
          --region ${AWS_REGION} --query 'DBInstances[0].[DBInstanceStatus,PubliclyAccessible]' \
          --output text 2>/dev/null)
        [ "$(echo $RDS_STATUS | awk '{print $1}')" = "available" ] && \
        [ "$(echo $RDS_STATUS | awk '{print $2}')" = "True" ] && break
        sleep 5; WAIT_COUNT=$((WAIT_COUNT + 1))
    done
    sleep 10

    docker pull postgres:15 >/dev/null 2>&1
    SCHEMA_OUTPUT=$(cat schema.sql | docker run -i --rm -e PGPASSWORD=${DB_PASSWORD} postgres:15 \
      psql -h ${DB_ENDPOINT} -U ${DB_USER} -d ${DB_NAME} -v ON_ERROR_STOP=1 2>&1)

    if [ $? -eq 0 ] && ! echo "$SCHEMA_OUTPUT" | grep -qi "ERROR\|FATAL"; then
        echo -e "${GREEN}✓ Schema ejecutado${NC}"; SCHEMA_EXECUTED=true
    else
        echo -e "${RED}✗ Error en schema:${NC}"; echo "$SCHEMA_OUTPUT" | grep -i "ERROR\|FATAL" | head -3
    fi

    aws ec2 revoke-security-group-ingress --group-id ${SG_ID} \
      --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,IpRanges=[{CidrIp=${MY_IP}/32}]" \
      --region ${AWS_REGION} 2>/dev/null || true
    aws rds modify-db-instance --db-instance-identifier ${DB_INSTANCE_NAME} \
      --no-publicly-accessible --apply-immediately --region ${AWS_REGION} >/dev/null 2>&1
    echo -e "${GREEN}✓ RDS vuelto a privado${NC}"
else
    echo -e "${YELLOW}⚠️  schema.sql no encontrado o Docker no disponible${NC}"
fi
export SCHEMA_STATUS=$SCHEMA_EXECUTED

# ============================================================
# PASO 7: IAM ROLE LAMBDA
# ============================================================
echo -e "\n${BLUE}PASO 7: Verificando IAM roles...${NC}"

cat > lambda-role-trust.json << 'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF

aws iam create-role --role-name ${PROJECT_NAME}-lambda-role \
  --assume-role-policy-document file://lambda-role-trust.json \
  2>/dev/null && echo "Lambda IAM role creado" || echo -e "${YELLOW}Lambda IAM role ya existe${NC}"

aws iam attach-role-policy --role-name ${PROJECT_NAME}-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
aws iam attach-role-policy --role-name ${PROJECT_NAME}-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess 2>/dev/null || true

cat > lambda-vpc-policy.json << EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["ec2:CreateNetworkInterface","ec2:DescribeNetworkInterfaces","ec2:DeleteNetworkInterface","ec2:AssignPrivateIpAddresses","ec2:UnassignPrivateIpAddresses"],"Resource":"*"}]}
EOF

aws iam put-role-policy --role-name ${PROJECT_NAME}-lambda-role \
  --policy-name LambdaVPCAccess \
  --policy-document file://lambda-vpc-policy.json 2>/dev/null || true

echo "Esperando 10s propagación IAM..."; sleep 10

# ============================================================
# PASO 8: LAMBDA PROCESSOR
# ============================================================
echo -e "\n${BLUE}PASO 8: Creando/Actualizando Lambda processor...${NC}"

ENV_VARS="Variables={DB_HOST=${DB_ENDPOINT},DB_NAME=${DB_NAME},DB_USER=${DB_USER},DB_PASSWORD=${DB_PASSWORD},OPENAI_API_KEY=${OPENAI_API_KEY},VECTORSTORE_BACKEND=pgvector,CHUNKING_STRATEGY=recursive,COLLECTION_NAME=rag_docs}"

EXISTING_LAMBDA=$(aws lambda get-function --function-name ${LAMBDA_PROCESSOR} --region ${AWS_REGION} 2>/dev/null)
if [ $? -eq 0 ]; then
  echo -e "${YELLOW}Actualizando Lambda processor...${NC}"
  aws lambda update-function-code --function-name ${LAMBDA_PROCESSOR} \
    --image-uri ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_PROCESSOR}:latest \
    --region ${AWS_REGION}
  sleep 5
  aws lambda update-function-configuration --function-name ${LAMBDA_PROCESSOR} \
    --environment "${ENV_VARS}" --region ${AWS_REGION}
else
  aws lambda create-function \
    --function-name ${LAMBDA_PROCESSOR} \
    --package-type Image \
    --code ImageUri=${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_PROCESSOR}:latest \
    --role arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PROJECT_NAME}-lambda-role \
    --timeout 900 --memory-size 1024 \
    --vpc-config SubnetIds=${SUBNET_ARRAY[0]},${SUBNET_ARRAY[1]},SecurityGroupIds=${SG_ID} \
    --environment "${ENV_VARS}" \
    --region ${AWS_REGION}
fi
echo -e "${GREEN}Lambda processor configurada${NC}"

# ============================================================
# PASO 9: ESPERAR LAMBDA ACTIVA
# ============================================================
echo -e "\n${BLUE}Esperando Lambda activa...${NC}"
aws lambda wait function-active-v2 --function-name ${LAMBDA_PROCESSOR} \
  --region ${AWS_REGION} 2>/dev/null && \
  echo -e "${GREEN}✓ Processor Lambda activa${NC}" || echo -e "${YELLOW}⚠️  Aún inicializando${NC}"
sleep 10

# ============================================================
# PASO 10: S3 TRIGGER
# ============================================================
echo -e "\n${BLUE}PASO 10: Configurando S3 trigger...${NC}"

aws lambda add-permission --function-name ${LAMBDA_PROCESSOR} \
  --statement-id s3-trigger --action lambda:InvokeFunction \
  --principal s3.amazonaws.com --source-arn arn:aws:s3:::${BUCKET_NAME} \
  --region ${AWS_REGION} 2>/dev/null || echo -e "${YELLOW}Permiso S3 ya existe${NC}"

cat > s3-notification.json << EOF
{"LambdaFunctionConfigurations":[{"LambdaFunctionArn":"arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:${LAMBDA_PROCESSOR}","Events":["s3:ObjectCreated:*"],"Filter":{"Key":{"FilterRules":[{"Name":"prefix","Value":"docs/"}]}}}]}
EOF

MAX_RETRIES=3; RETRY_COUNT=0; S3_CONFIGURED=false
while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$S3_CONFIGURED" = false ]; do
  [ $RETRY_COUNT -gt 0 ] && sleep 10
  if aws s3api put-bucket-notification-configuration \
    --bucket ${BUCKET_NAME} --notification-configuration file://s3-notification.json 2>/dev/null; then
    S3_CONFIGURED=true; echo -e "${GREEN}S3 trigger configurado${NC}"
  else
    RETRY_COUNT=$((RETRY_COUNT + 1))
  fi
done

# ============================================================
# PASO 11: IAM EC2 + SECURITY GROUP + EC2 STREAMLIT
# ============================================================
echo -e "\n${BLUE}PASO 11: Desplegando Streamlit en EC2...${NC}"

# IAM Role para EC2
aws iam create-role --role-name ${EC2_ROLE_NAME} \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  2>/dev/null && echo "EC2 IAM role creado" || echo -e "${YELLOW}EC2 IAM role ya existe${NC}"
aws iam attach-role-policy --role-name ${EC2_ROLE_NAME} \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess 2>/dev/null || true
aws iam create-instance-profile --instance-profile-name ${EC2_INSTANCE_PROFILE} \
  2>/dev/null && echo "Instance Profile creado" || echo -e "${YELLOW}Instance Profile ya existe${NC}"
aws iam add-role-to-instance-profile --instance-profile-name ${EC2_INSTANCE_PROFILE} \
  --role-name ${EC2_ROLE_NAME} 2>/dev/null || true
echo "Esperando 10s IAM..."; sleep 10

# Security Group EC2
EC2_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${EC2_SG_NAME}" \
  --query 'SecurityGroups[0].GroupId' --output text --region ${AWS_REGION} 2>/dev/null)
if [ "$EC2_SG_ID" = "" ] || [ "$EC2_SG_ID" = "None" ]; then
  EC2_SG_ID=$(aws ec2 create-security-group \
    --group-name ${EC2_SG_NAME} --description "Streamlit UI" \
    --vpc-id ${VPC_ID} --region ${AWS_REGION} --query 'GroupId' --output text)
  echo -e "${GREEN}EC2 SG creado: ${EC2_SG_ID}${NC}"
else
  echo -e "${YELLOW}EC2 SG ya existe: ${EC2_SG_ID}${NC}"
fi
aws ec2 authorize-security-group-ingress \
  --group-id ${EC2_SG_ID} --protocol tcp --port 8501 --cidr 0.0.0.0/0 \
  --region ${AWS_REGION} 2>/dev/null || true
# Permitir que EC2 acceda a RDS
aws ec2 authorize-security-group-ingress \
  --group-id ${SG_ID} --protocol tcp --port 5432 --source-group ${EC2_SG_ID} \
  --region ${AWS_REGION} 2>/dev/null || true

# Subir archivos RAG a S3 para que la EC2 los descargue
echo "Subiendo archivos RAG a S3..."
aws s3 cp app.py      s3://${BUCKET_NAME}/streamlit/app.py      --region ${AWS_REGION} 2>/dev/null || true
aws s3 cp pipeline.py s3://${BUCKET_NAME}/streamlit/pipeline.py --region ${AWS_REGION} 2>/dev/null || true
aws s3 cp config.py   s3://${BUCKET_NAME}/streamlit/config.py   --region ${AWS_REGION} 2>/dev/null || true
aws s3 cp setup.yaml  s3://${BUCKET_NAME}/streamlit/setup.yaml  --region ${AWS_REGION} 2>/dev/null || true

# AMI Amazon Linux 2023
AMI_ID=$(aws ec2 describe-images --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text --region ${AWS_REGION})
echo "AMI: ${AMI_ID}"

# User data
cat > ec2-userdata.sh << USERDATA
#!/bin/bash
yum update -y
yum install -y python3 python3-pip gcc postgresql-devel

pip3 install streamlit requests langchain langchain-community langchain-openai langchain-text-splitters psycopg2-binary pgvector pyyaml python-dotenv

# Descargar app.py y módulo rag
mkdir -p /home/ec2-user/rag
aws s3 cp s3://${BUCKET_NAME}/streamlit/app.py      /home/ec2-user/app.py           --region ${AWS_REGION}
aws s3 cp s3://${BUCKET_NAME}/streamlit/pipeline.py /home/ec2-user/rag/pipeline.py  --region ${AWS_REGION}
aws s3 cp s3://${BUCKET_NAME}/streamlit/config.py   /home/ec2-user/rag/config.py    --region ${AWS_REGION}
aws s3 cp s3://${BUCKET_NAME}/streamlit/setup.yaml  /home/ec2-user/rag/setup.yaml   --region ${AWS_REGION}
touch /home/ec2-user/rag/__init__.py

# Archivo de configuración con credenciales
cat > /home/ec2-user/.rag-deployment-config << 'EOF'
DB_HOST=${DB_ENDPOINT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
OPENAI_API_KEY=${OPENAI_API_KEY}
VECTORSTORE_BACKEND=pgvector
CHUNKING_STRATEGY=recursive
COLLECTION_NAME=rag_docs
EOF

chown -R ec2-user:ec2-user /home/ec2-user/

# Servicio systemd
cat > /etc/systemd/system/streamlit.service << 'EOF'
[Unit]
Description=Streamlit RAG Chatbot
After=network.target

[Service]
User=ec2-user
WorkingDirectory=/home/ec2-user
EnvironmentFile=/home/ec2-user/.rag-deployment-config
ExecStart=/usr/local/bin/streamlit run app.py --server.port=8501 --server.address=0.0.0.0 --server.headless=true
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable streamlit
systemctl start streamlit
USERDATA

# Lanzar o reusar EC2
EXISTING_EC2=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${EC2_NAME}" "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text --region ${AWS_REGION} 2>/dev/null)

if [ "$EXISTING_EC2" = "" ] || [ "$EXISTING_EC2" = "None" ]; then
  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id ${AMI_ID} --instance-type t3.micro \
    --security-group-ids ${EC2_SG_ID} --subnet-id ${SUBNET_ARRAY[0]} \
    --associate-public-ip-address \
    --user-data file://ec2-userdata.sh \
    --iam-instance-profile Name=${EC2_INSTANCE_PROFILE} \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${EC2_NAME}}]" \
    --region ${AWS_REGION} --query 'Instances[0].InstanceId' --output text)
  echo -e "${GREEN}EC2 lanzada: ${INSTANCE_ID}${NC}"
  aws ec2 wait instance-running --instance-ids ${INSTANCE_ID} --region ${AWS_REGION}
else
  INSTANCE_ID=${EXISTING_EC2}
  echo -e "${YELLOW}EC2 ya existe: ${INSTANCE_ID}${NC}"
  aws ssm send-command --instance-ids ${INSTANCE_ID} \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"aws s3 cp s3://${BUCKET_NAME}/streamlit/app.py /home/ec2-user/app.py\",\"systemctl restart streamlit\"]" \
    --region ${AWS_REGION} 2>/dev/null || echo -e "${YELLOW}SSM no disponible${NC}"
fi

rm -f ec2-userdata.sh

EC2_PUBLIC_IP=$(aws ec2 describe-instances --instance-ids ${INSTANCE_ID} \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region ${AWS_REGION})
STREAMLIT_URL="http://${EC2_PUBLIC_IP}:8501"

# ============================================================
# RESUMEN FINAL
# ============================================================
PROCESSOR_STATE=$(aws lambda get-function --function-name ${LAMBDA_PROCESSOR} \
  --region ${AWS_REGION} --query 'Configuration.State' --output text 2>/dev/null || echo "UNKNOWN")
S3_TRIGGER=$(aws s3api get-bucket-notification-configuration --bucket ${BUCKET_NAME} \
  --query 'LambdaFunctionConfigurations[0].LambdaFunctionArn' --output text 2>/dev/null || echo "NOT_CONFIGURED")

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} DESPLIEGUE COMPLETADO${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}BASE DE DATOS (pgvector):${NC}"
echo "  Host:     ${DB_ENDPOINT}"
echo "  Database: ${DB_NAME} / User: ${DB_USER}"
echo ""
echo -e "${BLUE}LAMBDA PROCESSOR:${NC}"
echo "  Función: ${LAMBDA_PROCESSOR}  [${PROCESSOR_STATE}]"
echo "  Trigger: S3 → docs/ → indexa en pgvector"
echo ""
echo -e "${BLUE}INTERFAZ STREAMLIT:${NC}"
echo "  URL: ${STREAMLIT_URL}  (disponible en ~3-5 min)"
echo ""
echo -e "${BLUE}ESTADO:${NC}"
[ "$PROCESSOR_STATE" = "Active" ] && echo -e "  Lambda Processor: ${GREEN}✓ Active${NC}" || echo -e "  Lambda Processor: ${YELLOW}⚠️  ${PROCESSOR_STATE}${NC}"
[ "$S3_TRIGGER" != "NOT_CONFIGURED" ] && echo -e "  S3 Trigger:       ${GREEN}✓ Configured${NC}" || echo -e "  S3 Trigger:       ${YELLOW}⚠️  Not configured${NC}"
[ "$SCHEMA_STATUS" = "true" ] && echo -e "  DB Schema:        ${GREEN}✓ Initialized${NC}" || echo -e "  DB Schema:        ${RED}✗ NOT INITIALIZED${NC}"
echo ""
echo -e "${BLUE}USO:${NC}"
echo "  1. Subir documento:  aws s3 cp doc.pdf s3://${BUCKET_NAME}/docs/doc.pdf"
echo "  2. Esperar ~30s que Lambda lo indexe automáticamente"
echo "  3. Abrir chatbot:    ${STREAMLIT_URL}"
echo ""

# Guardar config
cat > .rag-deployment-config << EOF
AWS_REGION=${AWS_REGION}
PROJECT_NAME=${PROJECT_NAME}
BUCKET_NAME=${BUCKET_NAME}
DB_ENDPOINT=${DB_ENDPOINT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
LAMBDA_PROCESSOR=${LAMBDA_PROCESSOR}
STREAMLIT_URL=${STREAMLIT_URL}
EC2_INSTANCE_ID=${INSTANCE_ID}
EC2_SG_ID=${EC2_SG_ID}
EC2_ROLE_NAME=${EC2_ROLE_NAME}
EC2_INSTANCE_PROFILE=${EC2_INSTANCE_PROFILE}
AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID}
DB_INSTANCE_NAME=${DB_INSTANCE_NAME}
OPENAI_API_KEY=${OPENAI_API_KEY}
EOF

echo -e "${GREEN}Configuración guardada en .rag-deployment-config${NC}"
