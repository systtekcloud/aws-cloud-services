#!/usr/bin/env bash
# =============================================================================
# v1 — Cleanup: borra TODOS los recursos en orden correcto
# =============================================================================
set -euo pipefail

# shellcheck disable=SC1090
[[ -f ~/.ec2-lab-env ]] && source ~/.ec2-lab-env

: "${REGION:=eu-west-1}"
: "${PROJECT:=ec2-lab}"
: "${ACCOUNT_ID:=$(aws sts get-caller-identity --query Account --output text)}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

echo -e "${RED}ATENCIÓN: Este script borra todos los recursos del lab v1.${NC}"
echo -n "Confirma escribiendo 'borrar': "
read -r CONFIRM
[[ "$CONFIRM" != "borrar" ]] && { echo "Cancelado."; exit 0; }

# 1. ASG (termina instancias)
info "1/10 — ASG..."
aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name "${PROJECT}-asg-web" \
  --force-delete --region "$REGION" 2>/dev/null && success "ASG borrado." || warn "ASG no existe."
echo "  Esperando que las instancias terminen (60s)..."
sleep 60

# 2. ALB + Listener
info "2/10 — ALB..."
if [[ -n "${ALB_ARN:-}" ]]; then
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region "$REGION" && success "ALB borrado." || warn "ALB no existe."
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" --region "$REGION" 2>/dev/null || true
fi

# 3. Target Group
info "3/10 — Target Group..."
if [[ -n "${TG_ARN:-}" ]]; then
  aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region "$REGION" && success "TG borrado." || warn "TG no existe."
fi

# 4. Launch Template
info "4/10 — Launch Template..."
if [[ -n "${LT_ID:-}" ]]; then
  aws ec2 delete-launch-template --launch-template-id "$LT_ID" --region "$REGION" && success "LT borrado." || warn "LT no existe."
fi

# 5. VPC Endpoints
info "5/10 — VPC Endpoints..."
EP_IDS=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=tag:Project,Values=${PROJECT}" "Name=vpc-endpoint-state,Values=available,pending" \
  --region "$REGION" --query 'VpcEndpoints[*].VpcEndpointId' --output text)
[[ -n "$EP_IDS" ]] && aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $EP_IDS --region "$REGION" && success "Endpoints borrados." || warn "Sin endpoints."

# 6. Security Groups
info "6/10 — Security Groups..."
sleep 10  # Esperar liberación de ENIs del ALB
for SG_VAR in SG_EC2 SG_ALB; do
  SG_ID="${!SG_VAR:-}"
  if [[ -n "$SG_ID" ]]; then
    # Revocar reglas
    PERMS=$(aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$REGION" \
      --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null || echo "[]")
    [[ "$PERMS" != "[]" ]] && aws ec2 revoke-security-group-ingress \
      --group-id "$SG_ID" --ip-permissions "$PERMS" --region "$REGION" 2>/dev/null || true
    aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" \
      && success "SG $SG_ID borrado." || warn "SG $SG_ID: dependencias."
  fi
done

# 7. Subnets
info "7/10 — Subnets..."
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=tag:Project,Values=${PROJECT}" \
  --region "$REGION" --query 'Subnets[*].SubnetId' --output text)
for ID in $SUBNET_IDS; do
  aws ec2 delete-subnet --subnet-id "$ID" --region "$REGION" && success "Subnet $ID." || warn "Subnet $ID: error."
done

# 8. Route Tables
info "8/10 — Route Tables..."
RT_IDS=$(aws ec2 describe-route-tables \
  --filters "Name=tag:Project,Values=${PROJECT}" "Name=association.main,Values=false" \
  --region "$REGION" --query 'RouteTables[*].RouteTableId' --output text)
for ID in $RT_IDS; do
  aws ec2 delete-route-table --route-table-id "$ID" --region "$REGION" && success "RT $ID." || warn "RT $ID: error."
done

# 9. NAT GW + EIPs + IGW
info "9/10 — NAT GWs, EIPs, IGW..."
for NAT in "${NAT_A:-}" "${NAT_B:-}"; do
  [[ -n "$NAT" ]] && aws ec2 delete-nat-gateway --nat-gateway-id "$NAT" --region "$REGION" && echo "  NAT $NAT: borrando..." || true
done
[[ -n "${NAT_A:-}" ]] || [[ -n "${NAT_B:-}" ]] && {
  echo "  Esperando NAT GWs (~60s)..."
  sleep 60
}
for EIP in "${EIP_A:-}" "${EIP_B:-}"; do
  [[ -n "$EIP" ]] && aws ec2 release-address --allocation-id "$EIP" --region "$REGION" && success "EIP $EIP liberada." || true
done
if [[ -n "${IGW_ID:-}" ]] && [[ -n "${VPC_ID:-}" ]]; then
  aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION" 2>/dev/null || true
  aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$REGION" && success "IGW borrado." || warn "IGW: error."
fi

# 10. VPC
info "10/10 — VPC..."
if [[ -n "${VPC_ID:-}" ]]; then
  aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" && success "VPC $VPC_ID borrada." || warn "VPC: quedan recursos."
fi

# IAM (opcional, no bloquea)
info "IAM: limpiando roles..."
aws iam remove-role-from-instance-profile \
  --instance-profile-name "${PROJECT}-instance-profile" \
  --role-name "${PROJECT}-instance-role" 2>/dev/null || true
aws iam delete-instance-profile \
  --instance-profile-name "${PROJECT}-instance-profile" 2>/dev/null || true
for POLICY in "${PROJECT}-s3-assets" "${PROJECT}-secrets"; do
  aws iam delete-role-policy --role-name "${PROJECT}-instance-role" --policy-name "$POLICY" 2>/dev/null || true
done
aws iam detach-role-policy --role-name "${PROJECT}-instance-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
aws iam detach-role-policy --role-name "${PROJECT}-instance-role" \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy 2>/dev/null || true
aws iam delete-role --role-name "${PROJECT}-instance-role" 2>/dev/null && success "IAM role borrado." || true

# Limpiar env file
rm -f ~/.ec2-lab-env
aws ec2 delete-key-pair --key-name "${PROJECT}-key" --region "$REGION" 2>/dev/null || true
rm -f ~/.ssh/${PROJECT}-key.pem

echo ""
success "=== Cleanup v1 completado. Coste: 0€/mes ==="
