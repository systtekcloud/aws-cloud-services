#!/usr/bin/env bash
# ==============================================================================
# Lab v2 ShopAPI — Paso 1: VPC y Networking
# ==============================================================================
# Crea la infraestructura de red completa:
#   - VPC 10.0.0.0/16
#   - 2 subnets públicas  (10.0.1.0/24 AZ-a, 10.0.2.0/24 AZ-b)
#   - 2 subnets privadas  (10.0.11.0/24 AZ-a, 10.0.12.0/24 AZ-b)
#   - Internet Gateway
#   - NAT Gateway con Elastic IP (en subnet pública AZ-a)
#   - Route tables: pública (→ IGW) y privada (→ NAT)
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuracion
# ------------------------------------------------------------------------------
REGION="eu-west-1"
AZ_A="eu-west-1a"
AZ_B="eu-west-1b"

VPC_CIDR="10.0.0.0/16"
PUBLIC_CIDR_A="10.0.1.0/24"
PUBLIC_CIDR_B="10.0.2.0/24"
PRIVATE_CIDR_A="10.0.11.0/24"
PRIVATE_CIDR_B="10.0.12.0/24"

PREFIX="shopapi"

# Archivo donde se guardan los IDs para usar en scripts posteriores
ENV_FILE="$(dirname "$0")/00-env.sh"

# ------------------------------------------------------------------------------
# Funciones auxiliares
# ------------------------------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] OK  $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ERR $*" >&2; exit 1; }

check_aws_cli() {
  if ! command -v aws &>/dev/null; then
    fail "AWS CLI no encontrado. Instalar con: pip install awscli"
  fi

  if ! aws sts get-caller-identity --region "$REGION" &>/dev/null; then
    fail "No hay credenciales AWS configuradas. Ejecutar: aws configure"
  fi

  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  log "Cuenta AWS: $ACCOUNT_ID | Region: $REGION"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
check_aws_cli

log "=========================================="
log " Iniciando creacion de red ShopAPI"
log "=========================================="

# ------------------------------------------------------------------------------
# 1. VPC
# ------------------------------------------------------------------------------
log "Creando VPC $VPC_CIDR..."

VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PREFIX}-vpc},{Key=Lab,Value=v2}]" \
  --region "$REGION" \
  --query 'Vpc.VpcId' \
  --output text)

# Habilitar hostnames DNS (necesario para ECS Fargate)
aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-hostnames \
  --region "$REGION"

aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-support \
  --region "$REGION"

ok "VPC creada: $VPC_ID"

# ------------------------------------------------------------------------------
# 2. Subnets públicas
# ------------------------------------------------------------------------------
log "Creando subnet pública AZ-a ($PUBLIC_CIDR_A)..."

PUBLIC_SUBNET_A=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PUBLIC_CIDR_A" \
  --availability-zone "$AZ_A" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PREFIX}-public-a},{Key=Type,Value=public},{Key=Lab,Value=v2}]" \
  --region "$REGION" \
  --query 'Subnet.SubnetId' \
  --output text)

ok "Subnet pública AZ-a: $PUBLIC_SUBNET_A"

log "Creando subnet pública AZ-b ($PUBLIC_CIDR_B)..."

PUBLIC_SUBNET_B=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PUBLIC_CIDR_B" \
  --availability-zone "$AZ_B" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PREFIX}-public-b},{Key=Type,Value=public},{Key=Lab,Value=v2}]" \
  --region "$REGION" \
  --query 'Subnet.SubnetId' \
  --output text)

ok "Subnet pública AZ-b: $PUBLIC_SUBNET_B"

# Habilitar asignacion automática de IP pública en subnets públicas
aws ec2 modify-subnet-attribute \
  --subnet-id "$PUBLIC_SUBNET_A" \
  --map-public-ip-on-launch \
  --region "$REGION"

aws ec2 modify-subnet-attribute \
  --subnet-id "$PUBLIC_SUBNET_B" \
  --map-public-ip-on-launch \
  --region "$REGION"

# ------------------------------------------------------------------------------
# 3. Subnets privadas
# ------------------------------------------------------------------------------
log "Creando subnet privada AZ-a ($PRIVATE_CIDR_A)..."

PRIVATE_SUBNET_A=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PRIVATE_CIDR_A" \
  --availability-zone "$AZ_A" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PREFIX}-private-a},{Key=Type,Value=private},{Key=Lab,Value=v2}]" \
  --region "$REGION" \
  --query 'Subnet.SubnetId' \
  --output text)

ok "Subnet privada AZ-a: $PRIVATE_SUBNET_A"

log "Creando subnet privada AZ-b ($PRIVATE_CIDR_B)..."

PRIVATE_SUBNET_B=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PRIVATE_CIDR_B" \
  --availability-zone "$AZ_B" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PREFIX}-private-b},{Key=Type,Value=private},{Key=Lab,Value=v2}]" \
  --region "$REGION" \
  --query 'Subnet.SubnetId' \
  --output text)

ok "Subnet privada AZ-b: $PRIVATE_SUBNET_B"

# ------------------------------------------------------------------------------
# 4. Internet Gateway
# ------------------------------------------------------------------------------
log "Creando Internet Gateway..."

IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PREFIX}-igw},{Key=Lab,Value=v2}]" \
  --region "$REGION" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)

ok "Internet Gateway creado: $IGW_ID"

log "Asociando IGW a la VPC..."

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$REGION"

ok "IGW asociado a $VPC_ID"

# ------------------------------------------------------------------------------
# 5. Elastic IP y NAT Gateway
# ------------------------------------------------------------------------------
log "Asignando Elastic IP para el NAT Gateway..."

EIP_ALLOC_ID=$(aws ec2 allocate-address \
  --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PREFIX}-nat-eip},{Key=Lab,Value=v2}]" \
  --region "$REGION" \
  --query 'AllocationId' \
  --output text)

EIP_PUBLIC_IP=$(aws ec2 describe-addresses \
  --allocation-ids "$EIP_ALLOC_ID" \
  --region "$REGION" \
  --query 'Addresses[0].PublicIp' \
  --output text)

ok "Elastic IP asignada: $EIP_PUBLIC_IP (AllocationId: $EIP_ALLOC_ID)"

log "Creando NAT Gateway en subnet pública AZ-a..."
log "  (esto puede tardar 60-90 segundos)"

NAT_GW_ID=$(aws ec2 create-nat-gateway \
  --subnet-id "$PUBLIC_SUBNET_A" \
  --allocation-id "$EIP_ALLOC_ID" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PREFIX}-nat},{Key=Lab,Value=v2}]" \
  --region "$REGION" \
  --query 'NatGateway.NatGatewayId' \
  --output text)

log "NAT Gateway creado: $NAT_GW_ID — esperando disponibilidad..."

aws ec2 wait nat-gateway-available \
  --filter "Name=nat-gateway-id,Values=$NAT_GW_ID" \
  --region "$REGION"

ok "NAT Gateway disponible: $NAT_GW_ID"

# ------------------------------------------------------------------------------
# 6. Route Table pública (tráfico saliente → IGW)
# ------------------------------------------------------------------------------
log "Creando route table pública..."

RT_PUBLIC_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PREFIX}-rt-public},{Key=Lab,Value=v2}]" \
  --region "$REGION" \
  --query 'RouteTable.RouteTableId' \
  --output text)

ok "Route table pública: $RT_PUBLIC_ID"

log "Añadiendo ruta 0.0.0.0/0 → IGW..."

aws ec2 create-route \
  --route-table-id "$RT_PUBLIC_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID" \
  --region "$REGION"

log "Asociando route table pública a subnets públicas..."

ASSOC_PUB_A=$(aws ec2 associate-route-table \
  --route-table-id "$RT_PUBLIC_ID" \
  --subnet-id "$PUBLIC_SUBNET_A" \
  --region "$REGION" \
  --query 'AssociationId' \
  --output text)

ASSOC_PUB_B=$(aws ec2 associate-route-table \
  --route-table-id "$RT_PUBLIC_ID" \
  --subnet-id "$PUBLIC_SUBNET_B" \
  --region "$REGION" \
  --query 'AssociationId' \
  --output text)

ok "Route table pública asociada (A: $ASSOC_PUB_A, B: $ASSOC_PUB_B)"

# ------------------------------------------------------------------------------
# 7. Route Table privada (tráfico saliente → NAT GW)
# ------------------------------------------------------------------------------
log "Creando route table privada..."

RT_PRIVATE_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PREFIX}-rt-private},{Key=Lab,Value=v2}]" \
  --region "$REGION" \
  --query 'RouteTable.RouteTableId' \
  --output text)

ok "Route table privada: $RT_PRIVATE_ID"

log "Añadiendo ruta 0.0.0.0/0 → NAT GW..."

aws ec2 create-route \
  --route-table-id "$RT_PRIVATE_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id "$NAT_GW_ID" \
  --region "$REGION"

log "Asociando route table privada a subnets privadas..."

ASSOC_PRIV_A=$(aws ec2 associate-route-table \
  --route-table-id "$RT_PRIVATE_ID" \
  --subnet-id "$PRIVATE_SUBNET_A" \
  --region "$REGION" \
  --query 'AssociationId' \
  --output text)

ASSOC_PRIV_B=$(aws ec2 associate-route-table \
  --route-table-id "$RT_PRIVATE_ID" \
  --subnet-id "$PRIVATE_SUBNET_B" \
  --region "$REGION" \
  --query 'AssociationId' \
  --output text)

ok "Route table privada asociada (A: $ASSOC_PRIV_A, B: $ASSOC_PRIV_B)"

# ------------------------------------------------------------------------------
# 8. Guardar IDs en archivo de entorno
# ------------------------------------------------------------------------------
log "Guardando IDs en $ENV_FILE..."

cat > "$ENV_FILE" << EOF
#!/usr/bin/env bash
# ============================================================
# IDs de recursos creados en Lab v2 ShopAPI
# Generado automáticamente el $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

export REGION="${REGION}"
export ACCOUNT_ID="${ACCOUNT_ID}"

# VPC y subnets
export VPC_ID="${VPC_ID}"
export PUBLIC_SUBNET_A="${PUBLIC_SUBNET_A}"
export PUBLIC_SUBNET_B="${PUBLIC_SUBNET_B}"
export PRIVATE_SUBNET_A="${PRIVATE_SUBNET_A}"
export PRIVATE_SUBNET_B="${PRIVATE_SUBNET_B}"

# Internet Gateway
export IGW_ID="${IGW_ID}"

# NAT Gateway
export EIP_ALLOC_ID="${EIP_ALLOC_ID}"
export EIP_PUBLIC_IP="${EIP_PUBLIC_IP}"
export NAT_GW_ID="${NAT_GW_ID}"

# Route Tables
export RT_PUBLIC_ID="${RT_PUBLIC_ID}"
export RT_PRIVATE_ID="${RT_PRIVATE_ID}"

# (se completarán en 02-alb-y-sg.sh)
export ALB_SG_ID=""
export TASK_SG_ID=""
export ALB_ARN=""
export ALB_DNS=""
export TG_ARN=""
export LISTENER_ARN=""
EOF

ok "IDs guardados en $ENV_FILE"

# ------------------------------------------------------------------------------
# 9. Resumen final
# ------------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  RESUMEN DE RED CREADA — ShopAPI Lab v2"
echo "============================================================"
echo "  Region:            $REGION"
echo "  VPC:               $VPC_ID  ($VPC_CIDR)"
echo ""
echo "  Subnets publicas:"
echo "    AZ-a ($AZ_A):   $PUBLIC_SUBNET_A  ($PUBLIC_CIDR_A)"
echo "    AZ-b ($AZ_B):   $PUBLIC_SUBNET_B  ($PUBLIC_CIDR_B)"
echo ""
echo "  Subnets privadas:"
echo "    AZ-a ($AZ_A):   $PRIVATE_SUBNET_A  ($PRIVATE_CIDR_A)"
echo "    AZ-b ($AZ_B):   $PRIVATE_SUBNET_B  ($PRIVATE_CIDR_B)"
echo ""
echo "  Internet Gateway:  $IGW_ID"
echo "  NAT Gateway:       $NAT_GW_ID  (IP: $EIP_PUBLIC_IP)"
echo ""
echo "  Route Tables:"
echo "    Publica:         $RT_PUBLIC_ID  → $IGW_ID"
echo "    Privada:         $RT_PRIVATE_ID  → $NAT_GW_ID"
echo "============================================================"
echo ""
echo "  Siguiente paso: ./02-alb-y-sg.sh"
echo "============================================================"
