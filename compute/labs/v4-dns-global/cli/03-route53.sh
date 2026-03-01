#!/usr/bin/env bash
# v4 — CLI 03: Route53 — A record Alias al ALB + Weighted policy
set -euo pipefail

source ~/.ec2-lab-env

SUBDOMAIN="${SUBDOMAIN:-app}"
FQDN="${SUBDOMAIN}.${DOMAIN}"

echo "=== v4: Configurando Route53 para ${FQDN} ==="

# ALB Zone ID (necesario para el Alias record)
ALB_ZONE_ID=$(aws elbv2 describe-load-balancers \
  --names "${PROJECT}-alb" \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names "${PROJECT}-alb" \
  --query 'LoadBalancers[0].DNSName' --output text)

echo "ALB: $ALB_DNS (Zone: $ALB_ZONE_ID)"
echo "Hosted Zone: $HOSTED_ZONE_ID"

# Bajar TTL del dominio raíz 48h antes de cambios (buena práctica)
# En este lab lo dejamos en 60s para pruebas rápidas

# A record Alias → ALB (EvaluateTargetHealth=true para failover automático)
cat > /tmp/r53-change.json << EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${FQDN}",
      "Type": "A",
      "SetIdentifier": "primary-eu-west-1",
      "Weight": 100,
      "AliasTarget": {
        "HostedZoneId": "${ALB_ZONE_ID}",
        "DNSName": "${ALB_DNS}",
        "EvaluateTargetHealth": true
      }
    }
  }]
}
EOF

CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file:///tmp/r53-change.json \
  --query 'ChangeInfo.Id' --output text)

echo "Cambio Route53 enviado: $CHANGE_ID"
echo "Esperando propagación..."
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"

echo ""
echo "Registro creado: ${FQDN} → ALIAS → ${ALB_DNS}"
echo ""
echo "Verificación:"
echo "  dig ${FQDN} +short"
echo "  curl -L https://${FQDN}/health"

cat >> ~/.ec2-lab-env << EOF

# v4 — Route53
export FQDN="$FQDN"
export ALB_ZONE_ID="$ALB_ZONE_ID"
EOF

echo "=== Route53 configurado ==="
