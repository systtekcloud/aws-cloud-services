#!/usr/bin/env bash
# v4 — Cleanup: GA + Route53 records + HTTPS listener + ACM cert
set -euo pipefail

source ~/.ec2-lab-env

echo "ADVERTENCIA: Esto elimina GA, registros DNS y el certificado ACM de v4."
read -rp "Escribe 'borrar' para confirmar: " CONFIRM
[ "$CONFIRM" == "borrar" ] || { echo "Abortado."; exit 0; }

echo "=== v4: Limpiando recursos ==="

# 1) Global Accelerator (endpoint group → listener → accelerator)
if [ -n "${GA_EG_ARN:-}" ]; then
  aws globalaccelerator delete-endpoint-group \
    --endpoint-group-arn "$GA_EG_ARN" \
    --region us-east-1 2>/dev/null && echo "GA Endpoint Group borrado" || true
fi

if [ -n "${GA_LISTENER_ARN:-}" ]; then
  aws globalaccelerator delete-listener \
    --listener-arn "$GA_LISTENER_ARN" \
    --region us-east-1 2>/dev/null && echo "GA Listener borrado" || true
fi

if [ -n "${GA_ARN:-}" ]; then
  aws globalaccelerator disable-accelerator \
    --accelerator-arn "$GA_ARN" \
    --region us-east-1 2>/dev/null
  sleep 5
  aws globalaccelerator delete-accelerator \
    --accelerator-arn "$GA_ARN" \
    --region us-east-1 2>/dev/null && echo "Global Accelerator borrado" || true
fi

# 2) Route53 — borrar A record
if [ -n "${FQDN:-}" ] && [ -n "${HOSTED_ZONE_ID:-}" ]; then
  ALB_DNS_NAME=$(aws elbv2 describe-load-balancers \
    --names "${PROJECT}-alb" \
    --query 'LoadBalancers[0].DNSName' --output text)

  cat > /tmp/r53-delete.json << EOF
{
  "Changes": [{
    "Action": "DELETE",
    "ResourceRecordSet": {
      "Name": "${FQDN}",
      "Type": "A",
      "SetIdentifier": "primary-eu-west-1",
      "Weight": 100,
      "AliasTarget": {
        "HostedZoneId": "${ALB_ZONE_ID}",
        "DNSName": "${ALB_DNS_NAME}",
        "EvaluateTargetHealth": true
      }
    }
  }]
}
EOF

  aws route53 change-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch file:///tmp/r53-delete.json 2>/dev/null && \
    echo "Route53 A record borrado" || true
fi

# 3) Listener HTTPS del ALB → restaurar HTTP:80 a forward
if [ -n "${HTTPS_LISTENER_ARN:-}" ]; then
  aws elbv2 delete-listener \
    --listener-arn "$HTTPS_LISTENER_ARN" 2>/dev/null && \
    echo "Listener HTTPS borrado" || true
fi

# Restaurar HTTP:80 listener a forward al TG original
HTTP_LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$(aws elbv2 describe-load-balancers \
    --names "${PROJECT}-alb" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)" \
  --query "Listeners[?Port==\`80\`].ListenerArn" --output text 2>/dev/null)

if [ -n "$HTTP_LISTENER_ARN" ]; then
  aws elbv2 modify-listener \
    --listener-arn "$HTTP_LISTENER_ARN" \
    --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" 2>/dev/null && \
    echo "HTTP:80 listener restaurado a forward" || true
fi

# 4) Certificado ACM (solo si está validado y sin recursos asociados)
if [ -n "${CERT_ARN:-}" ]; then
  aws acm delete-certificate \
    --certificate-arn "$CERT_ARN" 2>/dev/null && \
    echo "Certificado ACM borrado" || \
    echo "INFO: Cert en uso por otros recursos — borrar manualmente"
fi

echo "=== v4 limpiado. v1, v2 y v3 intactos. ==="
