#!/usr/bin/env bash
# v4 — CLI 02: Añadir listener HTTPS:443 al ALB + redirect HTTP→HTTPS
set -euo pipefail

source ~/.ec2-lab-env

echo "=== v4: Configurando HTTPS en el ALB ==="

ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${PROJECT}-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# Listener HTTPS:443
HTTPS_LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTPS \
  --port 443 \
  --certificates CertificateArn="$CERT_ARN" \
  --ssl-policy "ELBSecurityPolicy-TLS13-1-2-2021-06" \
  --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
  --query 'Listeners[0].ListenerArn' --output text)

echo "Listener HTTPS creado: $HTTPS_LISTENER_ARN"

# Modificar listener HTTP:80 para redirect permanente a HTTPS
HTTP_LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query "Listeners[?Port==\`80\`].ListenerArn" --output text)

aws elbv2 modify-listener \
  --listener-arn "$HTTP_LISTENER_ARN" \
  --default-actions 'Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}'

echo "HTTP:80 redirige permanentemente a HTTPS:443"

# Actualizar SG del ALB para permitir 443
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ALB_ID" \
  --protocol tcp \
  --port 443 \
  --cidr "0.0.0.0/0" 2>/dev/null || echo "INFO: Regla 443 ya existe"

cat >> ~/.ec2-lab-env << EOF

# v4 — HTTPS
export HTTPS_LISTENER_ARN="$HTTPS_LISTENER_ARN"
export ALB_ARN="$ALB_ARN"
EOF

echo "=== HTTPS configurado en el ALB ==="
echo "Test: curl -L http://${ALB_DNS}/health"
