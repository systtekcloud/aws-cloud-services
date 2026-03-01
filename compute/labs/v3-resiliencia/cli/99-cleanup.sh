#!/usr/bin/env bash
# v3 — Cleanup: Warm Pool + FIS + Blue/Green Green (NO borra v1/v2)
set -euo pipefail

source ~/.ec2-lab-env

echo "ADVERTENCIA: Esto elimina recursos de v3 (Warm Pool, FIS, ASG Green, TG Green)."
read -rp "Escribe 'borrar' para confirmar: " CONFIRM
[ "$CONFIRM" == "borrar" ] || { echo "Abortado."; exit 0; }

echo "=== v3: Limpiando recursos ==="

# 1) Restaurar listener a 100% Blue
if [ -n "${LISTENER_ARN:-}" ] && [ -n "${TG_BLUE_ARN:-}" ]; then
  aws elbv2 modify-listener \
    --listener-arn "$LISTENER_ARN" \
    --default-actions "[{\"Type\":\"forward\",\"TargetGroupArn\":\"$TG_BLUE_ARN\"}]" && \
    echo "Listener restaurado a 100% Blue" || true
fi

# 2) Borrar ASG Green
if [ -n "${ASG_GREEN:-}" ]; then
  aws autoscaling delete-auto-scaling-group \
    --auto-scaling-group-name "$ASG_GREEN" \
    --force-delete && echo "ASG Green borrado" || true
fi

# 3) Borrar TG Green (esperar a que el ASG libere instancias)
sleep 30
if [ -n "${TG_GREEN_ARN:-}" ]; then
  aws elbv2 delete-target-group \
    --target-group-arn "$TG_GREEN_ARN" && echo "TG Green borrado" || true
fi

# 4) Warm Pool
aws autoscaling delete-warm-pool \
  --auto-scaling-group-name "$ASG_NAME" \
  --force-delete 2>/dev/null && echo "Warm Pool borrado" || true

# 5) FIS
if [ -n "${FIS_TEMPLATE_ID:-}" ]; then
  aws fis delete-experiment-template \
    --id "$FIS_TEMPLATE_ID" 2>/dev/null && echo "FIS template borrado" || true
fi

# 6) Scheduled scaling actions
for ACTION in pico-manana pico-tarde; do
  aws autoscaling delete-scheduled-action \
    --auto-scaling-group-name "$ASG_NAME" \
    --scheduled-action-name "$ACTION" 2>/dev/null || true
done

# 7) Alarmas CW (Step Scaling)
for ALARM in "${ASG_NAME}-cpu-high" "${ASG_NAME}-cpu-low"; do
  aws cloudwatch delete-alarms --alarm-names "$ALARM" 2>/dev/null || true
done

# 8) Políticas de scaling (Step)
for POLICY in "${ASG_NAME}-step-scale-out" "${ASG_NAME}-step-scale-in"; do
  aws autoscaling delete-policy \
    --auto-scaling-group-name "$ASG_NAME" \
    --policy-name "$POLICY" 2>/dev/null || true
done

echo "=== v3 limpiado. v1 y v2 intactos. ==="
