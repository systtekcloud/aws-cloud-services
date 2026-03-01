#!/usr/bin/env bash
# v4 — CLI 04: Global Accelerator con endpoint ALB eu-west-1
# NOTA: Global Accelerator se administra globalmente desde us-east-1
set -euo pipefail

source ~/.ec2-lab-env

echo "=== v4: Creando Global Accelerator ==="

# GA es un recurso global — los comandos se ejecutan sin --region
# pero el endpoint (ALB) sí es regional

# Crear accelerator
GA_ARN=$(aws globalaccelerator create-accelerator \
  --name "${PROJECT}-ga" \
  --ip-address-type IPV4 \
  --enabled \
  --tags Key=Project,Value="$PROJECT" Key=Lab,Value=v4 \
  --region us-east-1 \
  --query 'Accelerator.AcceleratorArn' --output text)

echo "Global Accelerator creado: $GA_ARN"

# IPs anycast asignadas
GA_IPS=$(aws globalaccelerator describe-accelerator \
  --accelerator-arn "$GA_ARN" \
  --region us-east-1 \
  --query 'Accelerator.IpSets[0].IpAddresses' --output text)

echo "IPs anycast: $GA_IPS"

# Listener (TCP 80 + 443)
GA_LISTENER_ARN=$(aws globalaccelerator create-listener \
  --accelerator-arn "$GA_ARN" \
  --port-ranges '[{"FromPort":80,"ToPort":80},{"FromPort":443,"ToPort":443}]' \
  --protocol TCP \
  --region us-east-1 \
  --query 'Listener.ListenerArn' --output text)

echo "Listener GA: $GA_LISTENER_ARN"

# Endpoint Group — ALB en eu-west-1
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${PROJECT}-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

GA_EG_ARN=$(aws globalaccelerator create-endpoint-group \
  --listener-arn "$GA_LISTENER_ARN" \
  --endpoint-group-region "${REGION:-eu-west-1}" \
  --endpoint-configurations "EndpointId=${ALB_ARN},Weight=100,ClientIPPreservationEnabled=true" \
  --health-check-path "/health" \
  --health-check-interval-seconds 10 \
  --threshold-count 2 \
  --region us-east-1 \
  --query 'EndpointGroup.EndpointGroupArn' --output text)

echo "Endpoint Group GA: $GA_EG_ARN"

cat >> ~/.ec2-lab-env << EOF

# v4 — Global Accelerator
export GA_ARN="$GA_ARN"
export GA_LISTENER_ARN="$GA_LISTENER_ARN"
export GA_EG_ARN="$GA_EG_ARN"
export GA_IPS="$GA_IPS"
EOF

echo ""
echo "=== Global Accelerator listo ==="
echo "IPs anycast: $GA_IPS"
echo "Test (puede tardar 2-3 min en propagarse):"
echo "  curl https://${GA_IPS%% *}/health  (primera IP)"
echo ""
echo "IMPORTANTE: GA tiene coste por hora aunque no haya tráfico (~18€/mes)"
echo "  Eliminar cuando no se use: cli/99-cleanup.sh"
