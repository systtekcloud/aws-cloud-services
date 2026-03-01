#!/usr/bin/env bash
# =============================================================================
# v1 — Paso 2: VPC, subnets, IGW, NAT GW, route tables, S3 endpoint
# =============================================================================
set -euo pipefail

: "${REGION:=eu-west-1}"
: "${PROJECT:=ec2-lab}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

# -----------------------------------------------------------------------------
info "1/7 — Creando VPC 10.0.0.0/16..."
# -----------------------------------------------------------------------------
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[
    {Key=Name,Value=${PROJECT}-vpc},
    {Key=Project,Value=${PROJECT}}]" \
  --region "$REGION" \
  --query 'Vpc.VpcId' --output text)

aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames --region "$REGION"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support   --region "$REGION"
echo "VPC_ID=$VPC_ID" >> ~/.ec2-lab-env
success "VPC: $VPC_ID"

# -----------------------------------------------------------------------------
info "2/7 — Creando 9 subnets (3 AZs × 3 tiers)..."
# -----------------------------------------------------------------------------
declare -A SUBNETS
for IDX in 0 1 2; do
  AZ_LETTER=("a" "b" "c")
  AZ="${REGION}${AZ_LETTER[$IDX]}"

  # Públicas (ALB)
  PUB=$(aws ec2 create-subnet --vpc-id "$VPC_ID" \
    --cidr-block "10.0.$((IDX+1)).0/24" --availability-zone "$AZ" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=subnet-pub-${AZ_LETTER[$IDX]}},{Key=Project,Value=${PROJECT}},{Key=Tier,Value=public}]" \
    --region "$REGION" --query 'Subnet.SubnetId' --output text)
  SUBNETS["pub_${AZ_LETTER[$IDX]}"]=$PUB

  # Privadas app (EC2 ASG)
  APP=$(aws ec2 create-subnet --vpc-id "$VPC_ID" \
    --cidr-block "10.0.$((IDX+11)).0/24" --availability-zone "$AZ" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=subnet-app-${AZ_LETTER[$IDX]}},{Key=Project,Value=${PROJECT}},{Key=Tier,Value=app}]" \
    --region "$REGION" --query 'Subnet.SubnetId' --output text)
  SUBNETS["app_${AZ_LETTER[$IDX]}"]=$APP

  # Privadas DB (aisladas)
  DB=$(aws ec2 create-subnet --vpc-id "$VPC_ID" \
    --cidr-block "10.0.$((IDX+21)).0/24" --availability-zone "$AZ" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=subnet-db-${AZ_LETTER[$IDX]}},{Key=Project,Value=${PROJECT}},{Key=Tier,Value=db}]" \
    --region "$REGION" --query 'Subnet.SubnetId' --output text)
  SUBNETS["db_${AZ_LETTER[$IDX]}"]=$DB
done

# Exportar IDs
for KEY in "${!SUBNETS[@]}"; do
  echo "SUBNET_${KEY^^}=${SUBNETS[$KEY]}" >> ~/.ec2-lab-env
done
success "9 subnets creadas."

# Leer variables exportadas
# shellcheck disable=SC1090
source ~/.ec2-lab-env

# -----------------------------------------------------------------------------
info "3/7 — Internet Gateway..."
# -----------------------------------------------------------------------------
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT}-igw},{Key=Project,Value=${PROJECT}}]" \
  --region "$REGION" --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION"
echo "IGW_ID=$IGW_ID" >> ~/.ec2-lab-env
success "IGW: $IGW_ID"

# -----------------------------------------------------------------------------
info "4/7 — Elastic IPs y NAT Gateways (AZ-a y AZ-b para HA)..."
# -----------------------------------------------------------------------------
EIP_A=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PROJECT}-eip-nat-a},{Key=Project,Value=${PROJECT}}]" \
  --region "$REGION" --query 'AllocationId' --output text)
EIP_B=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PROJECT}-eip-nat-b},{Key=Project,Value=${PROJECT}}]" \
  --region "$REGION" --query 'AllocationId' --output text)

NAT_A=$(aws ec2 create-nat-gateway \
  --subnet-id "$SUBNET_PUB_A" --allocation-id "$EIP_A" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT}-nat-a},{Key=Project,Value=${PROJECT}}]" \
  --region "$REGION" --query 'NatGateway.NatGatewayId' --output text)
NAT_B=$(aws ec2 create-nat-gateway \
  --subnet-id "$SUBNET_PUB_B" --allocation-id "$EIP_B" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT}-nat-b},{Key=Project,Value=${PROJECT}}]" \
  --region "$REGION" --query 'NatGateway.NatGatewayId' --output text)

echo "NAT_A=$NAT_A" >> ~/.ec2-lab-env
echo "NAT_B=$NAT_B" >> ~/.ec2-lab-env
echo "EIP_A=$EIP_A"  >> ~/.ec2-lab-env
echo "EIP_B=$EIP_B"  >> ~/.ec2-lab-env

echo "  Esperando NAT GWs (~60s)..."
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_A" "$NAT_B" --region "$REGION"
success "NAT GWs disponibles: $NAT_A, $NAT_B"

# -----------------------------------------------------------------------------
info "5/7 — Route Tables..."
# -----------------------------------------------------------------------------
# RT pública → IGW
RT_PUB=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT}-rt-pub},{Key=Project,Value=${PROJECT}}]" \
  --region "$REGION" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RT_PUB" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" --region "$REGION"
for SUBNET in "$SUBNET_PUB_A" "$SUBNET_PUB_B" "$SUBNET_PUB_C"; do
  aws ec2 associate-route-table --route-table-id "$RT_PUB" --subnet-id "$SUBNET" --region "$REGION"
done

# RT privada AZ-a/c → NAT-a
RT_APP_A=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT}-rt-app-a},{Key=Project,Value=${PROJECT}}]" \
  --region "$REGION" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RT_APP_A" \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_A" --region "$REGION"
aws ec2 associate-route-table --route-table-id "$RT_APP_A" --subnet-id "$SUBNET_APP_A" --region "$REGION"
aws ec2 associate-route-table --route-table-id "$RT_APP_A" --subnet-id "$SUBNET_APP_C" --region "$REGION"

# RT privada AZ-b → NAT-b
RT_APP_B=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT}-rt-app-b},{Key=Project,Value=${PROJECT}}]" \
  --region "$REGION" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RT_APP_B" \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_B" --region "$REGION"
aws ec2 associate-route-table --route-table-id "$RT_APP_B" --subnet-id "$SUBNET_APP_B" --region "$REGION"

# RT DB (sin salida internet — aislada)
RT_DB=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT}-rt-db},{Key=Project,Value=${PROJECT}}]" \
  --region "$REGION" --query 'RouteTable.RouteTableId' --output text)
for SUBNET in "$SUBNET_DB_A" "$SUBNET_DB_B" "$SUBNET_DB_C"; do
  aws ec2 associate-route-table --route-table-id "$RT_DB" --subnet-id "$SUBNET" --region "$REGION"
done

for VAR in RT_PUB RT_APP_A RT_APP_B RT_DB; do
  echo "${VAR}=${!VAR}" >> ~/.ec2-lab-env
done
success "Route tables configuradas."

# -----------------------------------------------------------------------------
info "6/7 — S3 Gateway Endpoint (gratis, sin tráfico por NAT)..."
# -----------------------------------------------------------------------------
aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" \
  --service-name "com.amazonaws.${REGION}.s3" \
  --route-table-ids "$RT_APP_A" "$RT_APP_B" "$RT_DB" \
  --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=${PROJECT}-vpce-s3},{Key=Project,Value=${PROJECT}}]" \
  --region "$REGION" > /dev/null
success "S3 Gateway Endpoint creado."

# -----------------------------------------------------------------------------
info "7/7 — Verificación del networking..."
# -----------------------------------------------------------------------------
echo ""
echo "VPC ID         : $VPC_ID"
echo "Subnets públicas : $SUBNET_PUB_A, $SUBNET_PUB_B, $SUBNET_PUB_C"
echo "Subnets app      : $SUBNET_APP_A, $SUBNET_APP_B, $SUBNET_APP_C"
echo "Subnets db       : $SUBNET_DB_A, $SUBNET_DB_B, $SUBNET_DB_C"
echo "NAT GWs          : $NAT_A (AZ-a), $NAT_B (AZ-b)"
echo ""
echo "Variables guardadas en: ~/.ec2-lab-env"
echo "  → source ~/.ec2-lab-env para usarlas en scripts siguientes"
success "=== Networking completado ==="
