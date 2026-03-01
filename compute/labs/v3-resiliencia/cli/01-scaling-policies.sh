#!/usr/bin/env bash
# v3 — CLI 01: Políticas de scaling (Step + Scheduled)
set -euo pipefail

source ~/.ec2-lab-env

echo "=== v3: Configurando políticas de scaling avanzadas ==="

# ── Step Scaling para picos abruptos ─────────────────────────────────────────
# Target Tracking ya gestiona steady state (creado en v1)
# Step Scaling: si CPU > 80% durante 1 min → +2 instancias inmediatamente

# Primero crear las alarmas CloudWatch manualmente
ALARM_HIGH=$(aws cloudwatch put-metric-alarm \
  --alarm-name "${ASG_NAME}-cpu-high" \
  --metric-name CPUUtilization \
  --namespace AWS/EC2 \
  --statistic Average \
  --dimensions Name=AutoScalingGroupName,Value="$ASG_NAME" \
  --period 60 \
  --evaluation-periods 1 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --alarm-description "CPU > 80% — scale out agresivo" \
  --output text 2>&1 && echo "alarm-high" || echo "error")

ALARM_LOW=$(aws cloudwatch put-metric-alarm \
  --alarm-name "${ASG_NAME}-cpu-low" \
  --metric-name CPUUtilization \
  --namespace AWS/EC2 \
  --statistic Average \
  --dimensions Name=AutoScalingGroupName,Value="$ASG_NAME" \
  --period 300 \
  --evaluation-periods 3 \
  --threshold 20 \
  --comparison-operator LessThanThreshold \
  --alarm-description "CPU < 20% durante 15 min — scale in" \
  --output text 2>&1 && echo "alarm-low" || echo "error")

# Step Scaling — scale out
POLICY_OUT_ARN=$(aws autoscaling put-scaling-policy \
  --auto-scaling-group-name "$ASG_NAME" \
  --policy-name "${ASG_NAME}-step-scale-out" \
  --policy-type StepScaling \
  --adjustment-type ChangeInCapacity \
  --step-adjustments MetricIntervalLowerBound=0,MetricIntervalUpperBound=10,ScalingAdjustment=1 \
                     MetricIntervalLowerBound=10,ScalingAdjustment=2 \
  --estimated-instance-warmup 120 \
  --query 'PolicyARN' --output text)

# Step Scaling — scale in
POLICY_IN_ARN=$(aws autoscaling put-scaling-policy \
  --auto-scaling-group-name "$ASG_NAME" \
  --policy-name "${ASG_NAME}-step-scale-in" \
  --policy-type StepScaling \
  --adjustment-type ChangeInCapacity \
  --step-adjustments MetricIntervalUpperBound=0,ScalingAdjustment=-1 \
  --query 'PolicyARN' --output text)

# Conectar alarmas con políticas
aws cloudwatch put-metric-alarm \
  --alarm-name "${ASG_NAME}-cpu-high" \
  --alarm-actions "$POLICY_OUT_ARN"

aws cloudwatch put-metric-alarm \
  --alarm-name "${ASG_NAME}-cpu-low" \
  --alarm-actions "$POLICY_IN_ARN"

echo "Step Scaling configurado (out: +1/+2 si CPU>80%, in: -1 si CPU<20%)"

# ── Scheduled Scaling ─────────────────────────────────────────────────────────
# Horario pico: L-V 08:00-20:00 UTC — mínimo 4 instancias

aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name "$ASG_NAME" \
  --scheduled-action-name "pico-manana" \
  --recurrence "0 8 * * 1-5" \
  --min-size 4 \
  --max-size 10 \
  --desired-capacity 4

aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name "$ASG_NAME" \
  --scheduled-action-name "pico-tarde" \
  --recurrence "0 20 * * 1-5" \
  --min-size 2 \
  --max-size 6 \
  --desired-capacity 2

echo "Scheduled scaling: pico L-V 08:00-20:00 UTC (min=4), valle resto (min=2)"

echo "=== Políticas de scaling configuradas ==="
