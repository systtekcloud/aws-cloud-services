#!/usr/bin/env bash
# =============================================================================
# Lab v4 — Fase A1: Expandir a 3 Zonas de Disponibilidad (eu-west-1c)
# =============================================================================
# Descripcion: Añade una subnet publica y privada en eu-west-1c, las asocia
#              a las route tables existentes, registra la subnet publica en el
#              ALB y actualiza el ECS Service para usar las 3 AZs.
#
# Prereqs:     Lab v3 completado. Variables de entorno exportadas (ver README).
# Uso:         bash 01-tres-az.sh
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Colores para output legible
# -----------------------------------------------------------------------------
VERDE='\033[0;32m'
AMARILLO='\033[1;33m'
ROJO='\033[0;31m'
NC='\033[0m' # Sin color

log_info()  { echo -e "${VERDE}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${AMARILLO}[WARN]${NC}  $1"; }
log_error() { echo -e "${ROJO}[ERROR]${NC} $1"; exit 1; }

# -----------------------------------------------------------------------------
# Variables de configuracion
# -----------------------------------------------------------------------------
REGION="${AWS_DEFAULT_REGION:-eu-west-1}"
CLUSTER="${CLUSTER:-shopapi-cluster}"
AZ_NUEVA="eu-west-1c"
CIDR_PUBLIC_C="10.0.3.0/24"
CIDR_PRIVATE_C="10.0.13.0/24"

log_info "Iniciando expansion a 3 AZs — Region: $REGION | AZ nueva: $AZ_NUEVA"

# -----------------------------------------------------------------------------
# Obtener recursos existentes de la VPC
# -----------------------------------------------------------------------------
log_info "Obteniendo recursos de la VPC..."

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=shopapi-vpc" \
  --query "Vpcs[0].VpcId" \
  --output text \
  --region "$REGION")

if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
  log_error "No se encontro la VPC shopapi-vpc. Verifica que el lab v3 esta completado."
fi
log_info "VPC encontrada: $VPC_ID"

# Obtener subnets existentes
PUBLIC_SUBNET_A=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=shopapi-public-a" \
  --query "Subnets[0].SubnetId" \
  --output text \
  --region "$REGION")

PUBLIC_SUBNET_B=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=shopapi-public-b" \
  --query "Subnets[0].SubnetId" \
  --output text \
  --region "$REGION")

PRIVATE_SUBNET_A=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=shopapi-private-a" \
  --query "Subnets[0].SubnetId" \
  --output text \
  --region "$REGION")

PRIVATE_SUBNET_B=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=shopapi-private-b" \
  --query "Subnets[0].SubnetId" \
  --output text \
  --region "$REGION")

log_info "Subnets existentes:"
log_info "  public-a:  $PUBLIC_SUBNET_A"
log_info "  public-b:  $PUBLIC_SUBNET_B"
log_info "  private-a: $PRIVATE_SUBNET_A"
log_info "  private-b: $PRIVATE_SUBNET_B"

# Obtener route tables
PUBLIC_RTB=$(aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=shopapi-public-rtb" \
  --query "RouteTables[0].RouteTableId" \
  --output text \
  --region "$REGION")

PRIVATE_RTB=$(aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=shopapi-private-rtb" \
  --query "RouteTables[0].RouteTableId" \
  --output text \
  --region "$REGION")

log_info "Route tables: public=$PUBLIC_RTB | private=$PRIVATE_RTB"

# Obtener ALB y ECS Security Group
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names shopapi-alb \
  --query "LoadBalancers[0].LoadBalancerArn" \
  --output text \
  --region "$REGION")

ECS_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=shopapi-ecs-sg" \
  --query "SecurityGroups[0].GroupId" \
  --output text \
  --region "$REGION")

log_info "ALB ARN: $ALB_ARN"
log_info "ECS Security Group: $ECS_SG"

# -----------------------------------------------------------------------------
# Paso 1: Crear subnet publica en eu-west-1c
# -----------------------------------------------------------------------------
log_info "Paso 1/6 — Creando subnet publica en $AZ_NUEVA ($CIDR_PUBLIC_C)..."

# Comprobar si ya existe para idempotencia
EXISTING_PUBLIC_C=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=shopapi-public-c" "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[0].SubnetId" \
  --output text \
  --region "$REGION")

if [[ "$EXISTING_PUBLIC_C" != "None" && -n "$EXISTING_PUBLIC_C" ]]; then
  log_warn "La subnet publica-c ya existe: $EXISTING_PUBLIC_C (saltando creacion)"
  PUBLIC_SUBNET_C="$EXISTING_PUBLIC_C"
else
  PUBLIC_SUBNET_C=$(aws ec2 create-subnet \
    --vpc-id "$VPC_ID" \
    --cidr-block "$CIDR_PUBLIC_C" \
    --availability-zone "$AZ_NUEVA" \
    --query "Subnet.SubnetId" \
    --output text \
    --region "$REGION")

  aws ec2 create-tags \
    --resources "$PUBLIC_SUBNET_C" \
    --tags \
      Key=Name,Value=shopapi-public-c \
      Key=Tier,Value=public \
      Key=Proyecto,Value=shopapi \
      Key=Lab,Value=v4 \
    --region "$REGION"

  # Habilitar auto-asignacion de IP publica
  aws ec2 modify-subnet-attribute \
    --subnet-id "$PUBLIC_SUBNET_C" \
    --map-public-ip-on-launch \
    --region "$REGION"

  log_info "Subnet publica-c creada: $PUBLIC_SUBNET_C"
fi

# -----------------------------------------------------------------------------
# Paso 2: Crear subnet privada en eu-west-1c
# -----------------------------------------------------------------------------
log_info "Paso 2/6 — Creando subnet privada en $AZ_NUEVA ($CIDR_PRIVATE_C)..."

EXISTING_PRIVATE_C=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=shopapi-private-c" "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[0].SubnetId" \
  --output text \
  --region "$REGION")

if [[ "$EXISTING_PRIVATE_C" != "None" && -n "$EXISTING_PRIVATE_C" ]]; then
  log_warn "La subnet privada-c ya existe: $EXISTING_PRIVATE_C (saltando creacion)"
  PRIVATE_SUBNET_C="$EXISTING_PRIVATE_C"
else
  PRIVATE_SUBNET_C=$(aws ec2 create-subnet \
    --vpc-id "$VPC_ID" \
    --cidr-block "$CIDR_PRIVATE_C" \
    --availability-zone "$AZ_NUEVA" \
    --query "Subnet.SubnetId" \
    --output text \
    --region "$REGION")

  aws ec2 create-tags \
    --resources "$PRIVATE_SUBNET_C" \
    --tags \
      Key=Name,Value=shopapi-private-c \
      Key=Tier,Value=private \
      Key=Proyecto,Value=shopapi \
      Key=Lab,Value=v4 \
    --region "$REGION"

  log_info "Subnet privada-c creada: $PRIVATE_SUBNET_C"
fi

# -----------------------------------------------------------------------------
# Paso 3: Asociar route tables
# -----------------------------------------------------------------------------
log_info "Paso 3/6 — Asociando route tables a las nuevas subnets..."

# Funcion para asociar route table (idempotente)
asociar_rtb() {
  local SUBNET_ID="$1"
  local RTB_ID="$2"
  local NOMBRE="$3"

  # Comprobar si ya esta asociada
  ASSOC=$(aws ec2 describe-route-tables \
    --route-table-ids "$RTB_ID" \
    --query "RouteTables[0].Associations[?SubnetId=='$SUBNET_ID'].RouteTableAssociationId" \
    --output text \
    --region "$REGION")

  if [[ -n "$ASSOC" && "$ASSOC" != "None" ]]; then
    log_warn "  Route table $RTB_ID ya asociada a $NOMBRE ($SUBNET_ID)"
  else
    ASSOC_ID=$(aws ec2 associate-route-table \
      --subnet-id "$SUBNET_ID" \
      --route-table-id "$RTB_ID" \
      --query "AssociationId" \
      --output text \
      --region "$REGION")
    log_info "  Route table $RTB_ID asociada a $NOMBRE: $ASSOC_ID"
  fi
}

asociar_rtb "$PUBLIC_SUBNET_C"  "$PUBLIC_RTB"  "public-c"
asociar_rtb "$PRIVATE_SUBNET_C" "$PRIVATE_RTB" "private-c"

# -----------------------------------------------------------------------------
# Paso 4: Registrar subnet publica en el ALB
# -----------------------------------------------------------------------------
log_info "Paso 4/6 — Añadiendo subnet publica-c al ALB..."

aws elbv2 set-subnets \
  --load-balancer-arn "$ALB_ARN" \
  --subnets "$PUBLIC_SUBNET_A" "$PUBLIC_SUBNET_B" "$PUBLIC_SUBNET_C" \
  --region "$REGION"

log_info "ALB actualizado con 3 subnets"

# Verificar AZs del ALB
log_info "AZs del ALB:"
aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query "LoadBalancers[0].AvailabilityZones[*].{AZ:ZoneName,Subnet:SubnetId}" \
  --output table \
  --region "$REGION"

# -----------------------------------------------------------------------------
# Paso 5: Actualizar ECS Service con la tercera subnet privada
# -----------------------------------------------------------------------------
log_info "Paso 5/6 — Actualizando ECS Service shopapi-service con 3 subnets..."

aws ecs update-service \
  --cluster "$CLUSTER" \
  --service shopapi-service \
  --network-configuration "awsvpcConfiguration={
    subnets=[$PRIVATE_SUBNET_A,$PRIVATE_SUBNET_B,$PRIVATE_SUBNET_C],
    securityGroups=[$ECS_SG],
    assignPublicIp=DISABLED
  }" \
  --region "$REGION" \
  --output json | jq -r '.service | "Service actualizado: desiredCount=\(.desiredCount) runningCount=\(.runningCount)"' 2>/dev/null \
  || log_info "ECS Service actualizado (instala jq para ver detalles)"

# -----------------------------------------------------------------------------
# Paso 6: Verificar distribucion de tasks por AZ
# -----------------------------------------------------------------------------
log_info "Paso 6/6 — Verificando distribucion de tasks por AZ..."

echo ""
echo "Esperando 30 segundos para que ECS redistribuya los tasks..."
sleep 30

TASK_ARNS=$(aws ecs list-tasks \
  --cluster "$CLUSTER" \
  --service-name shopapi-service \
  --query "taskArns" \
  --output text \
  --region "$REGION")

if [[ -n "$TASK_ARNS" ]]; then
  aws ecs describe-tasks \
    --cluster "$CLUSTER" \
    --tasks $TASK_ARNS \
    --query "tasks[*].{AZ:availabilityZone,Estado:lastStatus,CP:capacityProviderName}" \
    --output table \
    --region "$REGION"
else
  log_warn "No hay tasks en ejecucion todavia. Espera un momento y ejecuta:"
  echo "  aws ecs list-tasks --cluster $CLUSTER --service-name shopapi-service"
fi

# -----------------------------------------------------------------------------
# Resumen final
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  EXPANSION A 3 AZs COMPLETADA"
echo "============================================================"
echo "  VPC:             $VPC_ID"
echo "  Subnet public-c: $PUBLIC_SUBNET_C ($CIDR_PUBLIC_C)"
echo "  Subnet private-c:$PRIVATE_SUBNET_C ($CIDR_PRIVATE_C)"
echo "  AZ:              $AZ_NUEVA"
echo "============================================================"
echo ""
echo "Siguiente paso: bash 02-autoscaling-api.sh"
