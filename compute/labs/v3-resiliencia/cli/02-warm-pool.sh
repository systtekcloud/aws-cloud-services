#!/usr/bin/env bash
# v3 — CLI 02: Warm Pool para scale-out rápido (<30s vs 2-3 min)
set -euo pipefail

source ~/.ec2-lab-env

echo "=== v3: Configurando Warm Pool ==="

# Warm Pool: 2 instancias pre-inicializadas en estado Stopped
# Cuando el ASG necesita escalar, las toma del pool en lugar de lanzar nuevas
aws autoscaling put-warm-pool \
  --auto-scaling-group-name "$ASG_NAME" \
  --pool-state Stopped \
  --min-size 2

echo "Warm Pool creado con 2 instancias en estado Stopped"
echo "Esperando a que las instancias del Warm Pool estén listas..."

# Verificar estado del Warm Pool
sleep 30
aws autoscaling describe-warm-pool \
  --auto-scaling-group-name "$ASG_NAME" \
  --query 'Instances[*].[InstanceId,LifecycleState,HealthStatus]' \
  --output table

echo ""
echo "Prueba de scale-out rápido:"
echo "  # Aumentar desired temporalmente y medir tiempo"
echo "  time aws autoscaling set-desired-capacity \\"
echo "    --auto-scaling-group-name $ASG_NAME \\"
echo "    --desired-capacity $(( $(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].DesiredCapacity' --output text) + 2 ))"
echo ""
echo "  # Las instancias del Warm Pool deberían estar InService en <30s"

echo "=== Warm Pool configurado ==="
