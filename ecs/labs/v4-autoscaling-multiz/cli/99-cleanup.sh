#!/usr/bin/env bash
# ── Lab v4 Cleanup — AutoScaling + Multi-AZ + SQS Workers ───────────────────
# Elimina todos los recursos creados en v4 (sin tocar los de v1-v3).
# Ejecutar DESPUÉS de completar el lab.
set -euo pipefail

# ── Variables ─────────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-eu-west-1}"
CLUSTER="shopapi-cluster"
API_SERVICE="shopapi-api"
WORKER_SERVICE="shopapi-worker"
SQS_QUEUE_NAME="shopapi-orders"
SQS_DLQ_NAME="shopapi-orders-dlq"

# Confirmación
echo "⚠️  Este script elimina los recursos de Lab v4:"
echo "   - ECS Service workers + scaling policies"
echo "   - SQS queues (orders + DLQ)"
echo "   - Auto Scaling policies de la API"
echo "   - Subnets de la tercera AZ (eu-west-1c)"
echo ""
read -rp "¿Continuar? [s/N] " CONFIRM
[[ "$CONFIRM" =~ ^[sS]$ ]] || { echo "Abortado."; exit 0; }

# ── 1. Eliminar Scheduled Scaling ─────────────────────────────────────────────
echo ""
echo "🗓️  Eliminando Scheduled Scaling..."

aws application-autoscaling delete-scheduled-action \
  --service-namespace ecs \
  --resource-id "service/${CLUSTER}/${API_SERVICE}" \
  --scalable-dimension ecs:service:DesiredCount \
  --scheduled-action-name "shopapi-black-friday-prewarm" \
  --region "$AWS_REGION" 2>/dev/null || echo "  (ya eliminado o no existía)"

# ── 2. Eliminar Scaling Policies ──────────────────────────────────────────────
echo ""
echo "📉  Eliminando Auto Scaling policies..."

for POLICY in "shopapi-api-target-tracking" "shopapi-api-cpu-step" "shopapi-worker-sqs"; do
  SERVICE=$(echo "$POLICY" | grep -q "worker" && echo "$WORKER_SERVICE" || echo "$API_SERVICE")
  aws application-autoscaling delete-scaling-policy \
    --service-namespace ecs \
    --resource-id "service/${CLUSTER}/${SERVICE}" \
    --scalable-dimension ecs:service:DesiredCount \
    --policy-name "$POLICY" \
    --region "$AWS_REGION" 2>/dev/null || echo "  Policy $POLICY ya eliminada"
done

# ── 3. Deregistrar Scalable Targets ───────────────────────────────────────────
echo ""
echo "🎯  Deregistrando scalable targets..."

for SERVICE in "$API_SERVICE" "$WORKER_SERVICE"; do
  aws application-autoscaling deregister-scalable-target \
    --service-namespace ecs \
    --resource-id "service/${CLUSTER}/${SERVICE}" \
    --scalable-dimension ecs:service:DesiredCount \
    --region "$AWS_REGION" 2>/dev/null || echo "  Target de $SERVICE ya eliminado"
done

# ── 4. Eliminar ECS Worker Service ────────────────────────────────────────────
echo ""
echo "🛑  Eliminando ECS Service de workers..."

WORKER_EXISTS=$(aws ecs describe-services \
  --cluster "$CLUSTER" \
  --services "$WORKER_SERVICE" \
  --query "services[?status=='ACTIVE'] | length(@)" \
  --output text 2>/dev/null || echo "0")

if [[ "$WORKER_EXISTS" -gt 0 ]]; then
  echo "  Escalando a 0..."
  aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$WORKER_SERVICE" \
    --desired-count 0 \
    --region "$AWS_REGION" > /dev/null

  echo "  Esperando drain de tasks (30s)..."
  sleep 30

  echo "  Eliminando service..."
  aws ecs delete-service \
    --cluster "$CLUSTER" \
    --service "$WORKER_SERVICE" \
    --force \
    --region "$AWS_REGION" > /dev/null
  echo "  ✅ Worker service eliminado"
else
  echo "  Worker service no encontrado, continuando..."
fi

# ── 5. Eliminar Task Definition workers ───────────────────────────────────────
echo ""
echo "📋  Deregistrando Task Definitions de workers..."

TASK_REVISIONS=$(aws ecs list-task-definitions \
  --family-prefix "shopapi-worker" \
  --query 'taskDefinitionArns' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

if [[ -n "$TASK_REVISIONS" ]]; then
  for TD in $TASK_REVISIONS; do
    aws ecs deregister-task-definition --task-definition "$TD" \
      --region "$AWS_REGION" > /dev/null
    echo "  Deregistrado: $TD"
  done
else
  echo "  Sin task definitions de worker"
fi

# ── 6. Eliminar SQS Queues ────────────────────────────────────────────────────
echo ""
echo "📨  Eliminando SQS queues..."

for QUEUE_NAME in "$SQS_QUEUE_NAME" "$SQS_DLQ_NAME"; do
  QUEUE_URL=$(aws sqs get-queue-url \
    --queue-name "$QUEUE_NAME" \
    --query 'QueueUrl' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")

  if [[ -n "$QUEUE_URL" ]]; then
    aws sqs delete-queue --queue-url "$QUEUE_URL" --region "$AWS_REGION"
    echo "  ✅ Cola eliminada: $QUEUE_NAME"
  else
    echo "  Cola $QUEUE_NAME no encontrada, continuando..."
  fi
done

# ── 7. Eliminar CloudWatch Alarms de workers ──────────────────────────────────
echo ""
echo "🔔  Eliminando CloudWatch alarms de workers..."

aws cloudwatch delete-alarms \
  --alarm-names \
    "shopapi-worker-sqs-backlog" \
    "shopapi-api-request-rate" \
  --region "$AWS_REGION" 2>/dev/null || echo "  (ya eliminadas)"

# ── 8. Eliminar subnets de AZ-c ───────────────────────────────────────────────
echo ""
echo "🌐  Nota: Las subnets de eu-west-1c requieren eliminar manualmente"
echo "   o via: aws ec2 delete-subnet --subnet-id SUBNET_ID"
echo ""
echo "   Para encontrar los IDs:"
echo "   aws ec2 describe-subnets \\"
echo "     --filters 'Name=tag:Name,Values=shopapi-*-c' \\"
echo "     --query 'Subnets[].{Name:Tags[?Key==\`Name\`]|[0].Value,ID:SubnetId}' \\"
echo "     --output table"

# ── Resumen ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "✅  Cleanup de Lab v4 completado"
echo ""
echo "Recursos de v1-v3 conservados:"
echo "  - ECS Cluster + Service API (sin auto scaling)"
echo "  - VPC + ALB + 2 AZs"
echo "  - Secrets Manager + IAM Roles"
echo "  - CloudWatch Logs"
echo ""
echo "Para limpiar también v1-v3, ejecutar en orden:"
echo "  v3/cli/99-cleanup.sh → v2/cli/99-cleanup.sh → v1/cli/99-cleanup.sh"
echo "═══════════════════════════════════════════════════════"
