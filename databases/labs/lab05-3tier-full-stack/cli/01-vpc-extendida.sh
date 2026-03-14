#!/usr/bin/env bash
# =============================================================================
# Lab05 — Script 01: VPC 3-tier con 6 subnets, SGs, VPC Endpoints, EC2
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"
check_prereqs

# ---------------------------------------------------------------------------
section "PASO 1 — VPC"
# ---------------------------------------------------------------------------

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=cidr,Values=$VPC_CIDR" "Name=tag:Name,Values=$VPC_NAME" \
  --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
  VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME},{Key=Project,Value=$PROJECT},{Key=Lab,Value=$LAB}]" \
    --query 'Vpc.VpcId' --output text --region "$AWS_REGION")
  aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
  aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
  ok "VPC creada: $VPC_ID"
else
  ok "VPC ya existe: $VPC_ID"
fi
save_resource "VPC_ID" "$VPC_ID"

# ---------------------------------------------------------------------------
section "PASO 2 — 6 Subnets"
# ---------------------------------------------------------------------------

declare -A SUBNETS=(
  ["subnet-public-a"]="$SUBNET_PUBLIC_A_CIDR $AZ_A"
  ["subnet-public-b"]="$SUBNET_PUBLIC_B_CIDR $AZ_B"
  ["subnet-private-app-a"]="$SUBNET_APP_A_CIDR $AZ_A"
  ["subnet-private-app-b"]="$SUBNET_APP_B_CIDR $AZ_B"
  ["subnet-private-db-a"]="$SUBNET_DB_A_CIDR $AZ_A"
  ["subnet-private-db-b"]="$SUBNET_DB_B_CIDR $AZ_B"
)

for NAME in "${!SUBNETS[@]}"; do
  CIDR_AZ=(${SUBNETS[$NAME]})
  CIDR="${CIDR_AZ[0]}"
  AZ="${CIDR_AZ[1]}"

  SN_ID=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidrBlock,Values=$CIDR" \
    --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

  if [[ "$SN_ID" == "None" || -z "$SN_ID" ]]; then
    SN_ID=$(aws ec2 create-subnet \
      --vpc-id "$VPC_ID" --cidr-block "$CIDR" --availability-zone "$AZ" \
      --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$NAME},{Key=Project,Value=$PROJECT}]" \
      --query 'Subnet.SubnetId' --output text --region "$AWS_REGION")
    ok "Subnet $NAME: $SN_ID"
  else
    ok "Subnet $NAME ya existe: $SN_ID"
  fi
  save_resource "SUBNET_${NAME//[-]/_}" "$SN_ID"
done

# ---------------------------------------------------------------------------
section "PASO 3 — IGW + NAT GW + EIPs"
# ---------------------------------------------------------------------------

# IGW
IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query 'InternetGateways[0].InternetGatewayId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")
if [[ "$IGW_ID" == "None" ]]; then
  IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=igw-lab05},{Key=Project,Value=$PROJECT}]" \
    --query 'InternetGateway.InternetGatewayId' --output text --region "$AWS_REGION")
  aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region "$AWS_REGION"
  ok "IGW creado y adjunto: $IGW_ID"
else
  ok "IGW ya existe: $IGW_ID"
fi
save_resource "IGW_ID" "$IGW_ID"

# EIP + NAT GW
NAT_GW_ID=$(aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
  --query 'NatGateways[0].NatGatewayId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")
if [[ "$NAT_GW_ID" == "None" || -z "$NAT_GW_ID" ]]; then
  EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=eip-nat-lab05},{Key=Project,Value=$PROJECT}]" \
    --query 'AllocationId' --output text --region "$AWS_REGION")
  save_resource "EIP_ALLOC" "$EIP_ALLOC"

  SUBNET_PUBLIC_A_ID=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidrBlock,Values=$SUBNET_PUBLIC_A_CIDR" \
    --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION")

  NAT_GW_ID=$(aws ec2 create-nat-gateway \
    --subnet-id $SUBNET_PUBLIC_A_ID --allocation-id $EIP_ALLOC \
    --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=nat-lab05},{Key=Project,Value=$PROJECT}]" \
    --query 'NatGateway.NatGatewayId' --output text --region "$AWS_REGION")

  log "Esperando NAT GW disponible (~90s)..."
  aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_GW_ID --region "$AWS_REGION"
  ok "NAT GW creado: $NAT_GW_ID"
else
  ok "NAT GW ya existe: $NAT_GW_ID"
fi
save_resource "NAT_GW_ID" "$NAT_GW_ID"

# ---------------------------------------------------------------------------
section "PASO 4 — Route Tables (3)"
# ---------------------------------------------------------------------------

create_or_get_rt() {
  local name="$1"
  local RT_ID=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$name" \
    --query 'RouteTables[0].RouteTableId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")
  if [[ "$RT_ID" == "None" ]]; then
    RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
      --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$name},{Key=Project,Value=$PROJECT}]" \
      --query 'RouteTable.RouteTableId' --output text --region "$AWS_REGION")
    ok "RT $name: $RT_ID"
  else
    ok "RT $name ya existe: $RT_ID"
  fi
  echo "$RT_ID"
}

RT_PUBLIC=$(create_or_get_rt "rt-public-lab05")
RT_APP=$(create_or_get_rt "rt-app-lab05")
RT_DB=$(create_or_get_rt "rt-db-lab05")

# Rutas
aws ec2 create-route --route-table-id $RT_PUBLIC \
  --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID \
  --region "$AWS_REGION" 2>/dev/null || true

aws ec2 create-route --route-table-id $RT_APP \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_GW_ID \
  --region "$AWS_REGION" 2>/dev/null || true

aws ec2 create-route --route-table-id $RT_DB \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_GW_ID \
  --region "$AWS_REGION" 2>/dev/null || true

# Asociar subnets a route tables
for CIDR in $SUBNET_PUBLIC_A_CIDR $SUBNET_PUBLIC_B_CIDR; do
  SN=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidrBlock,Values=$CIDR" \
    --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION")
  aws ec2 associate-route-table --route-table-id $RT_PUBLIC --subnet-id $SN --region "$AWS_REGION" 2>/dev/null || true
done
for CIDR in $SUBNET_APP_A_CIDR $SUBNET_APP_B_CIDR; do
  SN=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidrBlock,Values=$CIDR" \
    --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION")
  aws ec2 associate-route-table --route-table-id $RT_APP --subnet-id $SN --region "$AWS_REGION" 2>/dev/null || true
done
for CIDR in $SUBNET_DB_A_CIDR $SUBNET_DB_B_CIDR; do
  SN=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidrBlock,Values=$CIDR" \
    --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION")
  aws ec2 associate-route-table --route-table-id $RT_DB --subnet-id $SN --region "$AWS_REGION" 2>/dev/null || true
done

save_resource "RT_PUBLIC" "$RT_PUBLIC"
save_resource "RT_APP" "$RT_APP"
save_resource "RT_DB" "$RT_DB"
ok "Route Tables configuradas"

# ---------------------------------------------------------------------------
section "PASO 5 — Security Groups (4)"
# ---------------------------------------------------------------------------

create_sg() {
  local name="$1" desc="$2"
  local ID=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$name" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")
  if [[ "$ID" == "None" ]]; then
    ID=$(aws ec2 create-security-group --group-name "$name" --description "$desc" \
      --vpc-id "$VPC_ID" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$PROJECT},{Key=Lab,Value=$LAB}]" \
      --query 'GroupId' --output text --region "$AWS_REGION")
    ok "SG $name: $ID"
  else
    ok "SG $name ya existe: $ID"
  fi
  echo "$ID"
}

SG_ALB=$(create_sg "sg-alb-lab05" "ALB public")
SG_APP=$(create_sg "sg-app-lab05" "App tier from ALB")
SG_AURORA=$(create_sg "sg-aurora-lab05" "Aurora from App only")
SG_REDIS=$(create_sg "sg-redis-lab05" "Redis from App only")

# Reglas inbound (solo si no existen)
aws ec2 authorize-security-group-ingress --group-id $SG_ALB \
  --ip-permissions IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}] \
  --region "$AWS_REGION" 2>/dev/null || true
aws ec2 authorize-security-group-ingress --group-id $SG_APP \
  --protocol tcp --port 8080 --source-group $SG_ALB --region "$AWS_REGION" 2>/dev/null || true
aws ec2 authorize-security-group-ingress --group-id $SG_APP \
  --protocol tcp --port 443 --source-group $SG_ALB --region "$AWS_REGION" 2>/dev/null || true
aws ec2 authorize-security-group-ingress --group-id $SG_AURORA \
  --protocol tcp --port 3306 --source-group $SG_APP --region "$AWS_REGION" 2>/dev/null || true
aws ec2 authorize-security-group-ingress --group-id $SG_REDIS \
  --protocol tcp --port 6379 --source-group $SG_APP --region "$AWS_REGION" 2>/dev/null || true

save_resource "SG_ALB" "$SG_ALB"
save_resource "SG_APP" "$SG_APP"
save_resource "SG_AURORA" "$SG_AURORA"
save_resource "SG_REDIS" "$SG_REDIS"

# ---------------------------------------------------------------------------
section "PASO 6 — VPC Endpoints"
# ---------------------------------------------------------------------------

# Gateway Endpoint para DynamoDB
DDB_EP=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=com.amazonaws.$AWS_REGION.dynamodb" \
  --query 'VpcEndpoints[0].VpcEndpointId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [[ "$DDB_EP" == "None" ]]; then
  DDB_EP=$(aws ec2 create-vpc-endpoint \
    --vpc-id "$VPC_ID" \
    --service-name "com.amazonaws.$AWS_REGION.dynamodb" \
    --vpc-endpoint-type Gateway \
    --route-table-ids $RT_APP $RT_DB \
    --query 'VpcEndpoint.VpcEndpointId' --output text --region "$AWS_REGION")
  ok "Gateway Endpoint DynamoDB: $DDB_EP"
else
  ok "Gateway Endpoint DynamoDB ya existe: $DDB_EP"
fi

# Interface Endpoints para SSM (Session Manager)
SUBNET_APP_A_ID=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidrBlock,Values=$SUBNET_APP_A_CIDR" \
  --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION")
SUBNET_APP_B_ID=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidrBlock,Values=$SUBNET_APP_B_CIDR" \
  --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION")

for SVC in ssm ssmmessages ec2messages secretsmanager; do
  EP_EXISTS=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=com.amazonaws.$AWS_REGION.$SVC" \
    --query 'VpcEndpoints[0].VpcEndpointId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")
  if [[ "$EP_EXISTS" == "None" ]]; then
    aws ec2 create-vpc-endpoint \
      --vpc-id "$VPC_ID" \
      --service-name "com.amazonaws.$AWS_REGION.$SVC" \
      --vpc-endpoint-type Interface \
      --subnet-ids $SUBNET_APP_A_ID $SUBNET_APP_B_ID \
      --security-group-ids $SG_APP \
      --private-dns-enabled \
      --query 'VpcEndpoint.VpcEndpointId' --output text --region "$AWS_REGION" > /dev/null
    ok "Interface Endpoint $SVC creado"
  else
    ok "Interface Endpoint $SVC ya existe"
  fi
done

# ---------------------------------------------------------------------------
section "PASO 7 — IAM Role + EC2 App Server"
# ---------------------------------------------------------------------------

# IAM Role
ROLE_EXISTS=$(aws iam get-role --role-name ec2-app-lab05-role \
  --query 'Role.Arn' --output text 2>/dev/null || echo "None")
if [[ "$ROLE_EXISTS" == "None" ]]; then
  aws iam create-role --role-name ec2-app-lab05-role \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  for POLICY in AmazonSSMManagedInstanceCore AmazonDynamoDBFullAccess SecretsManagerReadWrite; do
    aws iam attach-role-policy --role-name ec2-app-lab05-role \
      --policy-arn arn:aws:iam::aws:policy/$POLICY
  done
  aws iam create-instance-profile --instance-profile-name ec2-app-lab05-profile 2>/dev/null || true
  aws iam add-role-to-instance-profile --instance-profile-name ec2-app-lab05-profile \
    --role-name ec2-app-lab05-role 2>/dev/null || true
  sleep 10
  ok "IAM Role ec2-app-lab05-role creado"
fi

# EC2
EC2_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=app-server-lab05" "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [[ "$EC2_ID" == "None" || -z "$EC2_ID" ]]; then
  AMI_ID=$(aws ssm get-parameter \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query 'Parameter.Value' --output text --region "$AWS_REGION")

  EC2_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID --instance-type t3.micro \
    --subnet-id $SUBNET_APP_A_ID \
    --no-associate-public-ip-address \
    --iam-instance-profile Name=ec2-app-lab05-profile \
    --security-group-ids $SG_APP \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=app-server-lab05},{Key=Project,Value=$PROJECT},{Key=Lab,Value=$LAB}]" \
    --query 'Instances[0].InstanceId' --output text --region "$AWS_REGION")

  aws ec2 wait instance-running --instance-ids $EC2_ID --region "$AWS_REGION"
  ok "EC2 app-server-lab05: $EC2_ID"
else
  ok "EC2 ya existe: $EC2_ID"
fi
save_resource "EC2_ID" "$EC2_ID"

# ---------------------------------------------------------------------------
section "RESUMEN"
# ---------------------------------------------------------------------------
echo ""
echo "  VPC:        $VPC_ID ($VPC_CIDR)"
echo "  IGW:        $IGW_ID"
echo "  NAT GW:     $NAT_GW_ID"
echo "  SG App:     $SG_APP"
echo "  SG Aurora:  $SG_AURORA"
echo "  SG Redis:   $SG_REDIS"
echo "  EC2:        $EC2_ID"
echo ""
echo "  Conectar a EC2:"
echo "    aws ssm start-session --target $EC2_ID --region $AWS_REGION"
echo ""
ok "Script 01 completado — VPC 3-tier lista"
