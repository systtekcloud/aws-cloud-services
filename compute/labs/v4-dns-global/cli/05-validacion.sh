#!/usr/bin/env bash
# v4 — CLI 05: Validación DNS + HTTPS + Global Accelerator
set -euo pipefail

source ~/.ec2-lab-env

echo "=== v4: Validación DNS + HTTPS + Global Accelerator ==="

# 1) Certificado ACM
echo ""
echo "--- 1. Estado del certificado ACM ---"
aws acm describe-certificate \
  --certificate-arn "$CERT_ARN" \
  --query 'Certificate.{Status:Status,FQDN:DomainName,Validation:DomainValidationOptions[0].ValidationStatus}' \
  --output table

# 2) Listeners ALB
echo ""
echo "--- 2. Listeners del ALB ---"
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${PROJECT}-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[*].[Port,Protocol,DefaultActions[0].Type]' \
  --output table

# 3) HTTPS health check vía ALB DNS
echo ""
echo "--- 3. HTTPS vía ALB DNS ---"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --resolve "${ALB_DNS}:443:$(dig +short "$ALB_DNS" | head -1)" \
  "https://${ALB_DNS}/health" 2>/dev/null || echo "000")
echo "HTTP code /health (bypass DNS): $HTTP_CODE"

# 4) Route53 resolución
echo ""
echo "--- 4. Route53 DNS resolution ---"
if [ -n "${FQDN:-}" ]; then
  echo "dig ${FQDN} +short:"
  dig "${FQDN}" +short 2>/dev/null || echo "DNS no propagado aún"

  echo ""
  echo "curl https://${FQDN}/health:"
  curl -sf "https://${FQDN}/health" | python3 -m json.tool 2>/dev/null || \
    echo "INFO: HTTPS no disponible (cert o DNS aún propagando)"
fi

# 5) Global Accelerator estado
echo ""
echo "--- 5. Global Accelerator ---"
if [ -n "${GA_ARN:-}" ]; then
  aws globalaccelerator describe-accelerator \
    --accelerator-arn "$GA_ARN" \
    --region us-east-1 \
    --query 'Accelerator.{Name:Name,Status:Status,IPs:IpSets[0].IpAddresses}' \
    --output table

  # Test con primera IP de GA
  GA_IP=$(echo "$GA_IPS" | awk '{print $1}')
  if [ -n "$GA_IP" ]; then
    echo "curl http://${GA_IP}/health:"
    curl -sf --connect-timeout 10 "http://${GA_IP}/health" 2>/dev/null || \
      echo "INFO: GA aún propagando (puede tardar 2-3 min)"
  fi
fi

echo ""
echo "=== Validación v4 completada ==="
