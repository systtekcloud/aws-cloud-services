#!/usr/bin/env bash
# v3 — CLI 04: Blue/Green con ALB Weighted Target Groups
# Sin TTL de DNS — corte instantáneo. Rollback en segundos.
set -euo pipefail

source ~/.ec2-lab-env

echo "=== v3: Configurando Blue/Green con Weighted Target Groups ==="

# Renombrar el TG actual como "Blue"
TG_BLUE_ARN="$TG_ARN"
echo "TG Blue (producción actual): $TG_BLUE_ARN"

# Crear TG Green (nueva versión)
TG_GREEN_ARN=$(aws elbv2 create-target-group \
  --name "${PROJECT}-tg-green" \
  --protocol HTTP \
  --port 8080 \
  --vpc-id "$VPC_ID" \
  --target-type instance \
  --health-check-path "/health" \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --matcher HttpCode=200 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 add-tags \
  --resource-arns "$TG_GREEN_ARN" \
  --tags Key=Name,Value="${PROJECT}-tg-green" Key=Project,Value="$PROJECT" Key=Env,Value=green

echo "TG Green creado: $TG_GREEN_ARN"

# Crear ASG Green (misma configuración que Blue, LT actual)
LT_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId' --output text)

ASG_GREEN="${ASG_NAME}-green"
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name "$ASG_GREEN" \
  --launch-template LaunchTemplateId="$LT_ID",Version='$Latest' \
  --min-size 1 \
  --max-size 4 \
  --desired-capacity 2 \
  --vpc-zone-identifier "$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].VPCZoneIdentifier' --output text)" \
  --health-check-type ELB \
  --health-check-grace-period 120 \
  --target-group-arns "$TG_GREEN_ARN" \
  --tags Key=Name,Value="${PROJECT}-app-green" \
         Key=Project,Value="$PROJECT" \
         Key=Lab,Value=v3

echo "ASG Green creado. Esperando instancias healthy..."
sleep 60

# Verificar que Green tiene instancias healthy antes de cortar tráfico
HEALTHY_GREEN=$(aws elbv2 describe-target-health \
  --target-group-arn "$TG_GREEN_ARN" \
  --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`] | length(@)' \
  --output text)

echo "Instancias healthy en Green: $HEALTHY_GREEN"

# Obtener ARN del listener
LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$(aws elbv2 describe-load-balancers \
    --names "${PROJECT}-alb" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)" \
  --query 'Listeners[0].ListenerArn' --output text)

echo ""
echo "=== Flujo Blue/Green ==="
echo ""
echo "1) Canary — 90% Blue / 10% Green:"
echo "   aws elbv2 modify-listener --listener-arn $LISTENER_ARN \\"
echo "     --default-actions '[{\"Type\":\"forward\",\"ForwardConfig\":{\"TargetGroups\":[{\"TargetGroupArn\":\"$TG_BLUE_ARN\",\"Weight\":90},{\"TargetGroupArn\":\"$TG_GREEN_ARN\",\"Weight\":10}]}}]'"
echo ""
echo "2) Corte completo — 0% Blue / 100% Green:"
echo "   aws elbv2 modify-listener --listener-arn $LISTENER_ARN \\"
echo "     --default-actions '[{\"Type\":\"forward\",\"ForwardConfig\":{\"TargetGroups\":[{\"TargetGroupArn\":\"$TG_BLUE_ARN\",\"Weight\":0},{\"TargetGroupArn\":\"$TG_GREEN_ARN\",\"Weight\":100}]}}]'"
echo ""
echo "3) Rollback instantáneo — 100% Blue / 0% Green:"
echo "   aws elbv2 modify-listener --listener-arn $LISTENER_ARN \\"
echo "     --default-actions '[{\"Type\":\"forward\",\"ForwardConfig\":{\"TargetGroups\":[{\"TargetGroupArn\":\"$TG_BLUE_ARN\",\"Weight\":100},{\"TargetGroupArn\":\"$TG_GREEN_ARN\",\"Weight\":0}]}}]'"
echo ""

# Ejecutar paso 1 automáticamente (canary)
aws elbv2 modify-listener \
  --listener-arn "$LISTENER_ARN" \
  --default-actions "[{\"Type\":\"forward\",\"ForwardConfig\":{\"TargetGroups\":[{\"TargetGroupArn\":\"$TG_BLUE_ARN\",\"Weight\":90},{\"TargetGroupArn\":\"$TG_GREEN_ARN\",\"Weight\":10}]}}]"

echo "Canary activado: 90% Blue / 10% Green"

cat >> ~/.ec2-lab-env << EOF

# v3 — Blue/Green
export TG_BLUE_ARN="$TG_BLUE_ARN"
export TG_GREEN_ARN="$TG_GREEN_ARN"
export ASG_GREEN="$ASG_GREEN"
export LISTENER_ARN="$LISTENER_ARN"
EOF

echo "=== Blue/Green configurado ==="
