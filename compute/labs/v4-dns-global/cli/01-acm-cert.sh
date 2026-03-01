#!/usr/bin/env bash
# v4 — CLI 01: Certificado ACM wildcard con validación DNS
# Prerequisito: dominio en Route53 (o ajustar la validación manualmente)
set -euo pipefail

source ~/.ec2-lab-env

DOMAIN="${DOMAIN:-systtekcloud.dev}"
CERT_REGION="${REGION:-eu-west-1}"

echo "=== v4: Solicitando certificado ACM wildcard para *.${DOMAIN} ==="

# Solicitar certificado wildcard
CERT_ARN=$(aws acm request-certificate \
  --domain-name "*.${DOMAIN}" \
  --subject-alternative-names "${DOMAIN}" \
  --validation-method DNS \
  --region "$CERT_REGION" \
  --query 'CertificateArn' --output text)

echo "Certificado solicitado: $CERT_ARN"
echo "Esperando a que ACM genere el registro CNAME de validación..."
sleep 15

# Obtener el CNAME de validación
VALIDATION=$(aws acm describe-certificate \
  --certificate-arn "$CERT_ARN" \
  --region "$CERT_REGION" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord')

CNAME_NAME=$(echo "$VALIDATION" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Name'])")
CNAME_VALUE=$(echo "$VALIDATION" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Value'])")

echo ""
echo "Añadir el siguiente CNAME en Route53 para validar el certificado:"
echo "  Nombre: $CNAME_NAME"
echo "  Valor:  $CNAME_VALUE"
echo ""

# Si el dominio está en Route53, crear el CNAME automáticamente
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "${DOMAIN}." \
  --query 'HostedZones[0].Id' --output text 2>/dev/null | sed 's|/hostedzone/||')

if [ "$HOSTED_ZONE_ID" != "None" ] && [ -n "$HOSTED_ZONE_ID" ]; then
  echo "Zona encontrada: $HOSTED_ZONE_ID — creando CNAME de validación automáticamente..."

  cat > /tmp/acm-validation.json << EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$CNAME_NAME",
      "Type": "CNAME",
      "TTL": 300,
      "ResourceRecords": [{"Value": "$CNAME_VALUE"}]
    }
  }]
}
EOF

  aws route53 change-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch file:///tmp/acm-validation.json > /dev/null

  echo "CNAME creado. Esperando validación del certificado (2-5 min)..."
  aws acm wait certificate-validated \
    --certificate-arn "$CERT_ARN" \
    --region "$CERT_REGION"
  echo "Certificado validado!"
else
  echo "Hosted Zone no encontrada. Crear el CNAME manualmente y luego:"
  echo "  aws acm wait certificate-validated --certificate-arn $CERT_ARN"
fi

cat >> ~/.ec2-lab-env << EOF

# v4 — ACM
export CERT_ARN="$CERT_ARN"
export DOMAIN="$DOMAIN"
export HOSTED_ZONE_ID="$HOSTED_ZONE_ID"
EOF

echo "=== Certificado ACM listo ==="
