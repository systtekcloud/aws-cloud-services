#!/usr/bin/env bash
# ==============================================================================
# Lab 01 — RDS MySQL: Paso 1 — VPC, Subnets, SGs, SSM Endpoints, EC2 App
# ==============================================================================
# Crea toda la infraestructura de red necesaria para el lab:
#   - VPC 10.20.0.0/16
#   - 5 subnets (2 públicas, 2 privadas DB, 1 privada app)
#   - Internet Gateway + NAT Gateway + Elastic IP
#   - Route Tables (pública → IGW, privada → NAT)
#   - 3 Security Groups (sg-app, sg-rds, sg-ssm-ep)
#   - 3 VPC Interface Endpoints para SSM (ssm, ssmmessages, ec2messages)
#   - IAM Role + Instance Profile para SSM
#   - EC2 t3.micro en subnet privada (acceso vía SSM, sin keypair)
#
# Uso:
#   source cli/00-env.sh && bash cli/01-vpc-y-sg.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-env.sh"
check_prereqs

# ==============================================================================
# PASO 1: VPC
# ==============================================================================
section "Paso 1/9 — Crear VPC"

VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME},{Key=Project,Value=$PROJECT},{Key=Lab,Value=$LAB},{Key=Env,Value=$ENV}]" \
  --query 'Vpc.VpcId' --output text --region "$REGION")

aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames --region "$REGION"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support --region "$REGION"

echo "VPC_ID=$VPC_ID" >> "$RESOURCES_FILE"
ok "VPC creada: $VPC_ID (CIDR: $VPC_CIDR, DNS habilitado)"

# ==============================================================================
# PASO 2: Subnets
# ==============================================================================
section "Paso 2/9 — Crear 5 subnets"

create_subnet() {
  local NAME="$1" CIDR="$2" AZ="$3"
  local ID
  ID=$(aws ec2 create-subnet \
    --vpc-id "$VPC_ID" \
    --cidr-block "$CIDR" \
    --availability-zone "$AZ" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$NAME},{Key=Project,Value=$PROJECT},{Key=Lab,Value=$LAB}]" \
    --query 'Subnet.SubnetId' --output text --region "$REGION")
  echo "SUBNET_${NAME//-/_//-/_}=$ID"
  ok "Subnet $NAME: $ID ($CIDR, $AZ)"
}

SUBNET_PUBLIC_A=$(create_subnet "$SUBNET_PUBLIC_A_NAME"  "$SUBNET_PUBLIC_A_CIDR"  "$AZ_A" | cut -d= -f2)
SUBNET_PUBLIC_B=$(create_subnet "$SUBNET_PUBLIC_B_NAME"  "$SUBNET_PUBLIC_B_CIDR"  "$AZ_B" | cut -d= -f2)
SUBNET_DB_A=$(create_subnet     "$SUBNET_DB_A_NAME"      "$SUBNET_DB_A_CIDR"      "$AZ_A" | cut -d= -f2)
SUBNET_DB_B=$(create_subnet     "$SUBNET_DB_B_NAME"      "$SUBNET_DB_B_CIDR"      "$AZ_B" | cut -d= -f2)
SUBNET_APP_A=$(create_subnet    "$SUBNET_APP_A_NAME"     "$SUBNET_APP_A_CIDR"     "$AZ_A" | cut -d= -f2)

# Habilitar auto-assign IP pública en subnets públicas
aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_PUBLIC_A" --map-public-ip-on-launch --region "$REGION"
aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_PUBLIC_B" --map-public-ip-on-launch --region "$REGION"

{
  echo "SUBNET_PUBLIC_A=$SUBNET_PUBLIC_A"
  echo "SUBNET_PUBLIC_B=$SUBNET_PUBLIC_B"
  echo "SUBNET_DB_A=$SUBNET_DB_A"
  echo "SUBNET_DB_B=$SUBNET_DB_B"
  echo "SUBNET_APP_A=$SUBNET_APP_A"
} >> "$RESOURCES_FILE"

# ==============================================================================
# PASO 3: Internet Gateway
# ==============================================================================
section "Paso 3/9 — Internet Gateway"

IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$IGW_NAME},{Key=Project,Value=$PROJECT}]" \
  --query 'InternetGateway.InternetGatewayId' --output text --region "$REGION")

aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION"
echo "IGW_ID=$IGW_ID" >> "$RESOURCES_FILE"
ok "IGW creado y adjuntado: $IGW_ID"

# ==============================================================================
# PASO 4: Elastic IP + NAT Gateway
# ==============================================================================
section "Paso 4/9 — NAT Gateway"

EIP_ALLOC=$(aws ec2 allocate-address \
  --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=eip-nat-db-labs},{Key=Project,Value=$PROJECT}]" \
  --query 'AllocationId' --output text --region "$REGION")

NAT_GW_ID=$(aws ec2 create-nat-gateway \
  --subnet-id "$SUBNET_PUBLIC_A" \
  --allocation-id "$EIP_ALLOC" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=$NAT_NAME},{Key=Project,Value=$PROJECT}]" \
  --query 'NatGateway.NatGatewayId' --output text --region "$REGION")

echo "EIP_ALLOC=$EIP_ALLOC" >> "$RESOURCES_FILE"
echo "NAT_GW_ID=$NAT_GW_ID" >> "$RESOURCES_FILE"

log "Esperando que el NAT Gateway esté disponible (~60s)..."
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID" --region "$REGION"
ok "NAT Gateway disponible: $NAT_GW_ID"

# ==============================================================================
# PASO 5: Route Tables
# ==============================================================================
section "Paso 5/9 — Route Tables"

# RT Pública (→ IGW)
RT_PUBLIC=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$RT_PUBLIC_NAME},{Key=Project,Value=$PROJECT}]" \
  --query 'RouteTable.RouteTableId' --output text --region "$REGION")
aws ec2 create-route --route-table-id "$RT_PUBLIC" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" --region "$REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$RT_PUBLIC" --subnet-id "$SUBNET_PUBLIC_A" --region "$REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$RT_PUBLIC" --subnet-id "$SUBNET_PUBLIC_B" --region "$REGION" > /dev/null
ok "RT-Public creada: $RT_PUBLIC"

# RT Privada (→ NAT)
RT_PRIVATE=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$RT_PRIVATE_NAME},{Key=Project,Value=$PROJECT}]" \
  --query 'RouteTable.RouteTableId' --output text --region "$REGION")
aws ec2 create-route --route-table-id "$RT_PRIVATE" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_GW_ID" --region "$REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$RT_PRIVATE" --subnet-id "$SUBNET_DB_A" --region "$REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$RT_PRIVATE" --subnet-id "$SUBNET_DB_B" --region "$REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$RT_PRIVATE" --subnet-id "$SUBNET_APP_A" --region "$REGION" > /dev/null
ok "RT-Private creada: $RT_PRIVATE"

echo "RT_PUBLIC=$RT_PUBLIC" >> "$RESOURCES_FILE"
echo "RT_PRIVATE=$RT_PRIVATE" >> "$RESOURCES_FILE"

# ==============================================================================
# PASO 6: Security Groups
# ==============================================================================
section "Paso 6/9 — Security Groups"

# sg-app: instancia de aplicación
SG_APP=$(aws ec2 create-security-group \
  --group-name "$SG_APP_NAME" \
  --description "SG para instancia de aplicacion (lab01 RDS)" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_APP_NAME},{Key=Project,Value=$PROJECT}]" \
  --query 'GroupId' --output text --region "$REGION")
ok "sg-app creado: $SG_APP (sin inbound - acceso via SSM)"

# sg-rds: instancia RDS (solo acepta de sg-app)
SG_RDS=$(aws ec2 create-security-group \
  --group-name "$SG_RDS_NAME" \
  --description "SG para RDS MySQL (lab01) - solo desde sg-app" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_RDS_NAME},{Key=Project,Value=$PROJECT}]" \
  --query 'GroupId' --output text --region "$REGION")

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_RDS" \
  --protocol tcp --port 3306 \
  --source-group "$SG_APP" \
  --region "$REGION" > /dev/null
ok "sg-rds creado: $SG_RDS (inbound 3306 solo desde sg-app)"

# sg-ssm-ep: VPC endpoints SSM
SG_SSM_EP=$(aws ec2 create-security-group \
  --group-name "$SG_SSM_EP_NAME" \
  --description "SG para VPC endpoints SSM (lab01)" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_SSM_EP_NAME},{Key=Project,Value=$PROJECT}]" \
  --query 'GroupId' --output text --region "$REGION")

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_SSM_EP" \
  --protocol tcp --port 443 \
  --cidr "$VPC_CIDR" \
  --region "$REGION" > /dev/null
ok "sg-ssm-ep creado: $SG_SSM_EP (inbound 443 desde VPC)"

echo "SG_APP=$SG_APP" >> "$RESOURCES_FILE"
echo "SG_RDS=$SG_RDS" >> "$RESOURCES_FILE"
echo "SG_SSM_EP=$SG_SSM_EP" >> "$RESOURCES_FILE"

# ==============================================================================
# PASO 7: VPC Endpoints SSM (para acceso sin internet)
# ==============================================================================
section "Paso 7/9 — VPC Interface Endpoints SSM"

for SVC_SUFFIX in ssm ssmmessages ec2messages; do
  EP_ID=$(aws ec2 create-vpc-endpoint \
    --vpc-id "$VPC_ID" \
    --vpc-endpoint-type Interface \
    --service-name "com.amazonaws.${REGION}.${SVC_SUFFIX}" \
    --subnet-ids "$SUBNET_APP_A" \
    --security-group-ids "$SG_SSM_EP" \
    --private-dns-enabled \
    --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=ep-${SVC_SUFFIX}-db-labs},{Key=Project,Value=$PROJECT}]" \
    --query 'VpcEndpoint.VpcEndpointId' --output text --region "$REGION")
  echo "VPC_EP_${SVC_SUFFIX^^}=$EP_ID" >> "$RESOURCES_FILE"
  ok "VPC Endpoint $SVC_SUFFIX: $EP_ID"
done

# ==============================================================================
# PASO 8: IAM Role + Instance Profile para SSM
# ==============================================================================
section "Paso 8/9 — IAM Role SSM"

TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

aws iam create-role \
  --role-name "$EC2_SSM_ROLE_NAME" \
  --assume-role-policy-document "$TRUST_POLICY" \
  --tags Key=Project,Value="$PROJECT" Key=Lab,Value="$LAB" \
  --region "$REGION" > /dev/null

aws iam attach-role-policy \
  --role-name "$EC2_SSM_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# Necesita también Secrets Manager para leer credenciales desde la EC2
aws iam attach-role-policy \
  --role-name "$EC2_SSM_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite

aws iam create-instance-profile \
  --instance-profile-name "$EC2_SSM_ROLE_NAME" > /dev/null

aws iam add-role-to-instance-profile \
  --instance-profile-name "$EC2_SSM_ROLE_NAME" \
  --role-name "$EC2_SSM_ROLE_NAME"

log "Esperando propagación IAM (10s)..."
sleep 10
ok "IAM Role + Instance Profile: $EC2_SSM_ROLE_NAME"

# ==============================================================================
# PASO 9: EC2 Instancia de aplicación
# ==============================================================================
section "Paso 9/9 — EC2 instancia de aplicación"

# Obtener AMI Amazon Linux 2023 más reciente
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text --region "$REGION")

EC2_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --subnet-id "$SUBNET_APP_A" \
  --security-group-ids "$SG_APP" \
  --iam-instance-profile Name="$EC2_SSM_ROLE_NAME" \
  --no-associate-public-ip-address \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$EC2_INSTANCE_NAME},{Key=Project,Value=$PROJECT},{Key=Lab,Value=$LAB},{Key=Env,Value=$ENV}]" \
  --query 'Instances[0].InstanceId' --output text --region "$REGION")

echo "EC2_ID=$EC2_ID" >> "$RESOURCES_FILE"

log "Esperando que la EC2 esté running..."
aws ec2 wait instance-running --instance-ids "$EC2_ID" --region "$REGION"
ok "EC2 creada: $EC2_ID ($EC2_INSTANCE_NAME)"

# ==============================================================================
# RESUMEN
# ==============================================================================
section "Infraestructura de red lista"

echo ""
ok "Todos los recursos de red creados:"
echo "  VPC:         $VPC_ID ($VPC_CIDR)"
echo "  IGW:         $IGW_ID"
echo "  NAT GW:      $NAT_GW_ID"
echo "  SG App:      $SG_APP"
echo "  SG RDS:      $SG_RDS"
echo "  EC2 App:     $EC2_ID"
echo ""
warn "IDs guardados en: $RESOURCES_FILE"
log "Siguiente: bash cli/02-rds-secreto.sh"
