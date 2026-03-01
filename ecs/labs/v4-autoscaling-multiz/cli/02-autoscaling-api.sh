#!/usr/bin/env bash
# =============================================================================
# Lab v4 — Fase A2: Auto Scaling de la API ShopAPI
# =============================================================================
# Descripcion: Configura tres mecanismos de escalado para el ECS Service de
#              la API:
#                1. Target Tracking por ALBRequestCountPerTarget (principal)
#                2. Step Scaling por CPU como guardrail secundario
#                3. Scheduled Action para pre-calentamiento Black Friday
#              Incluye stress test reproducible para disparar el escalado.
#
# Prereqs:     Fase A1 completada (3 AZs activas)
# Uso:         bash 02-autoscaling-api.sh
#              bash 02-autoscaling-api.sh --stress-test   (solo el stress test)
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Colores para output legible
# -----------------------------------------------------------------------------
VERDE='\033[0;32m'
AMARILLO='\033[1;33m'
AZUL='\033[0;34m'
ROJO='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${VERDE}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${AMARILLO}[WARN]${NC}  $1"; }
log_paso()  { echo -e "${AZUL}[PASO]${NC}  $1"; }
log_error() { echo -e "${ROJO}[ERROR]${NC} $1"; exit 1; }

# -----------------------------------------------------------------------------
# Variables de configuracion
# -----------------------------------------------------------------------------
REGION="${AWS_DEFAULT_REGION:-eu-west-1}"
CLUSTER="${CLUSTER:-shopapi-cluster}"
SERVICIO_API="shopapi-service"

# Limites de escalado de la API
API_MIN_CAPACITY=2
API_MAX_CAPACITY=10

# Target Tracking: 500 requests por task por minuto
ALB_TARGET_VALUE=500.0

# Step Scaling: escala si CPU > 80%
CPU_THRESHOLD_HIGH=80

# Black Friday: minimo 5 tasks de 20:00 a 22:00 UTC los viernes
BF_MIN_CAPACITY=5
BF_MAX_CAPACITY=15
BF_HORA_INICIO="20"
BF_HORA_FIN="22"

# Stress test: duracion y paralelismo
STRESS_PARALELO=10       # procesos en paralelo
STRESS_PETICIONES=1000   # peticiones por proceso

# Modo de ejecucion
MODO="${1:-full}"        # full | --stress-test | --monitor

# -----------------------------------------------------------------------------
# Funcion: obtener recursos de AWS
# -----------------------------------------------------------------------------
obtener_recursos() {
  log_info "Obteniendo recursos de AWS..."

  ALB_ARN=$(aws elbv2 describe-load-balancers \
    --names shopapi-alb \
    --query "LoadBalancers[0].LoadBalancerArn" \
    --output text \
    --region "$REGION")

  TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups \
    --load-balancer-arn "$ALB_ARN" \
    --query "TargetGroups[0].TargetGroupArn" \
    --output text \
    --region "$REGION")

  ALB_DNS=$(aws elbv2 describe-load-balancers \
    --names shopapi-alb \
    --query "LoadBalancers[0].DNSName" \
    --output text \
    --region "$REGION")

  # Extraer sufijos para la metrica ALB de Application Auto Scaling
  # Formato requerido: loadbalancer/app/shopapi-alb/XXXXX/targetgroup/shopapi-tg/YYYYY
  TG_SUFFIX=$(echo "$TARGET_GROUP_ARN" | sed 's|.*:||' | sed 's|targetgroup/|targetgroup/|')
  ALB_SUFFIX=$(echo "$ALB_ARN" | sed 's|.*:loadbalancer/||')

  RESOURCE_LABEL="$ALB_SUFFIX/$TG_SUFFIX"

  log_info "ALB ARN:         $ALB_ARN"
  log_info "Target Group:    $TARGET_GROUP_ARN"
  log_info "ALB DNS:         $ALB_DNS"
  log_info "Resource Label:  $RESOURCE_LABEL"
}

# =============================================================================
# MODO: SOLO STRESS TEST
# =============================================================================
if [[ "$MODO" == "--stress-test" ]]; then
  log_info "Modo stress test activado"
  obtener_recursos

  echo ""
  echo "============================================================"
  echo "  STRESS TEST — ShopAPI"
  echo "============================================================"
  echo "  ALB: http://$ALB_DNS"
  echo "  Procesos paralelos: $STRESS_PARALELO"
  echo "  Peticiones por proceso: $STRESS_PETICIONES"
  echo "  Total estimado: $((STRESS_PARALELO * STRESS_PETICIONES)) requests"
  echo "============================================================"
  echo ""
  echo "Monitoreando el servicio en tiempo real (Ctrl+C para parar):"
  echo ""

  # Lanzar monitor en background
  (
    while true; do
      INFO=$(aws ecs describe-services \
        --cluster "$CLUSTER" \
        --services "$SERVICIO_API" \
        --query "services[0].{D:desiredCount,R:runningCount,P:pendingCount}" \
        --output text \
        --region "$REGION" 2>/dev/null || echo "error error error")
      echo "$(date '+%H:%M:%S') | Tasks — desired=$(echo $INFO | awk '{print $1}') running=$(echo $INFO | awk '{print $2}') pending=$(echo $INFO | awk '{print $3}')"
      sleep 10
    done
  ) &
  MONITOR_PID=$!

  trap "kill $MONITOR_PID 2>/dev/null; echo 'Stress test detenido'" EXIT

  # Lanzar procesos de carga en paralelo
  echo "Iniciando carga..."
  for i in $(seq 1 "$STRESS_PARALELO"); do
    (
      COMPLETADAS=0
      for j in $(seq 1 "$STRESS_PETICIONES"); do
        curl -s -o /dev/null -w "" "http://$ALB_DNS/health" 2>/dev/null || true
        COMPLETADAS=$((COMPLETADAS + 1))
      done
      echo "Proceso $i: $COMPLETADAS peticiones completadas"
    ) &
  done

  wait
  echo ""
  echo "Stress test completado. Observa el escalado durante los proximos 2 minutos."
  echo "El scale-in ocurre despues del cooldown de 300 segundos."

  exit 0
fi

# =============================================================================
# MODO: SOLO MONITOR
# =============================================================================
if [[ "$MODO" == "--monitor" ]]; then
  obtener_recursos
  echo "Monitoreando Auto Scaling (Ctrl+C para parar)..."
  while true; do
    clear
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') ==="
    echo ""
    echo "--- ECS Service ---"
    aws ecs describe-services \
      --cluster "$CLUSTER" \
      --services "$SERVICIO_API" \
      --query "services[0].{Desired:desiredCount,Running:runningCount,Pending:pendingCount}" \
      --output table \
      --region "$REGION"
    echo ""
    echo "--- Actividades de Scaling (ultimas 5) ---"
    aws application-autoscaling describe-scaling-activities \
      --service-namespace ecs \
      --resource-id "service/$CLUSTER/$SERVICIO_API" \
      --max-results 5 \
      --query "ScalingActivities[*].{Tiempo:StartTime,Desc:Description}" \
      --output table \
      --region "$REGION" 2>/dev/null || echo "Sin actividad todavia"
    sleep 15
  done
  exit 0
fi

# =============================================================================
# MODO: CONFIGURACION COMPLETA (default)
# =============================================================================

obtener_recursos

echo ""
echo "============================================================"
echo "  CONFIGURANDO AUTO SCALING DE LA API"
echo "============================================================"
echo "  Cluster:     $CLUSTER"
echo "  Servicio:    $SERVICIO_API"
echo "  Min tasks:   $API_MIN_CAPACITY"
echo "  Max tasks:   $API_MAX_CAPACITY"
echo "============================================================"
echo ""

# -----------------------------------------------------------------------------
# Paso 1: Registrar el Scalable Target
# -----------------------------------------------------------------------------
log_paso "Paso 1/5 — Registrando Scalable Target en Application Auto Scaling..."

aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id "service/$CLUSTER/$SERVICIO_API" \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity "$API_MIN_CAPACITY" \
  --max-capacity "$API_MAX_CAPACITY" \
  --region "$REGION"

log_info "Scalable target registrado: min=$API_MIN_CAPACITY max=$API_MAX_CAPACITY"

# -----------------------------------------------------------------------------
# Paso 2: Target Tracking — ALBRequestCountPerTarget
# -----------------------------------------------------------------------------
log_paso "Paso 2/5 — Creando policy Target Tracking (ALBRequestCountPerTarget = $ALB_TARGET_VALUE)..."

aws application-autoscaling put-scaling-policy \
  --policy-name shopapi-api-target-tracking-alb \
  --service-namespace ecs \
  --resource-id "service/$CLUSTER/$SERVICIO_API" \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration "{
    \"TargetValue\": $ALB_TARGET_VALUE,
    \"PredefinedMetricSpecification\": {
      \"PredefinedMetricType\": \"ALBRequestCountPerTarget\",
      \"ResourceLabel\": \"$RESOURCE_LABEL\"
    },
    \"ScaleOutCooldown\": 60,
    \"ScaleInCooldown\": 300,
    \"DisableScaleIn\": false
  }" \
  --region "$REGION"

log_info "Policy creada: Target Tracking | ALBRequestCountPerTarget = $ALB_TARGET_VALUE"
log_info "  Scale out cooldown: 60s | Scale in cooldown: 300s"

# -----------------------------------------------------------------------------
# Paso 3: Alarma CloudWatch para CPU alta
# -----------------------------------------------------------------------------
log_paso "Paso 3/5 — Creando alarma CloudWatch CPU > ${CPU_THRESHOLD_HIGH}%..."

aws cloudwatch put-metric-alarm \
  --alarm-name shopapi-api-cpu-high \
  --alarm-description "CPU de la API por encima del ${CPU_THRESHOLD_HIGH}% durante 2 minutos consecutivos" \
  --namespace AWS/ECS \
  --metric-name CPUUtilization \
  --dimensions \
    Name=ClusterName,Value="$CLUSTER" \
    Name=ServiceName,Value="$SERVICIO_API" \
  --statistic Average \
  --period 60 \
  --evaluation-periods 2 \
  --threshold "$CPU_THRESHOLD_HIGH" \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --region "$REGION"

log_info "Alarma CloudWatch creada: shopapi-api-cpu-high"

# Step Scaling policy vinculada a la alarma
ALARM_ARN=$(aws cloudwatch describe-alarms \
  --alarm-names shopapi-api-cpu-high \
  --query "MetricAlarms[0].AlarmArn" \
  --output text \
  --region "$REGION")

STEP_POLICY_ARN=$(aws application-autoscaling put-scaling-policy \
  --policy-name shopapi-api-step-scaling-cpu \
  --service-namespace ecs \
  --resource-id "service/$CLUSTER/$SERVICIO_API" \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-type StepScaling \
  --step-scaling-policy-configuration "{
    \"AdjustmentType\": \"ChangeInCapacity\",
    \"StepAdjustments\": [
      {
        \"MetricIntervalLowerBound\": 0,
        \"MetricIntervalUpperBound\": 20,
        \"ScalingAdjustment\": 1
      },
      {
        \"MetricIntervalLowerBound\": 20,
        \"ScalingAdjustment\": 3
      }
    ],
    \"Cooldown\": 120,
    \"MetricAggregationType\": \"Average\"
  }" \
  --query "PolicyARN" \
  --output text \
  --region "$REGION")

log_info "Policy Step Scaling creada: $STEP_POLICY_ARN"

# Vincular la alarma a la policy de Step Scaling
aws cloudwatch put-metric-alarm \
  --alarm-name shopapi-api-cpu-high \
  --alarm-actions "$STEP_POLICY_ARN" \
  --region "$REGION" 2>/dev/null || \
log_warn "La alarma ya tiene la accion configurada"

log_info "Step Scaling configurado:"
log_info "  CPU 80-100%:  +1 task"
log_info "  CPU > 100%:   +3 tasks (situacion critica)"
log_info "  Cooldown:     120s"

# -----------------------------------------------------------------------------
# Paso 4: Scheduled Action — Black Friday
# -----------------------------------------------------------------------------
log_paso "Paso 4/5 — Configurando Scheduled Scaling para Black Friday..."

# Scale OUT: cada viernes a las 20:00 UTC
aws application-autoscaling put-scheduled-action \
  --service-namespace ecs \
  --resource-id "service/$CLUSTER/$SERVICIO_API" \
  --scalable-dimension ecs:service:DesiredCount \
  --scheduled-action-name shopapi-black-friday-scale-out \
  --schedule "cron($BF_HORA_INICIO 0 ? * FRI *)" \
  --scalable-target-action "MinCapacity=$BF_MIN_CAPACITY,MaxCapacity=$BF_MAX_CAPACITY" \
  --region "$REGION"

log_info "Scheduled Action SCALE OUT: viernes ${BF_HORA_INICIO}:00 UTC → min=$BF_MIN_CAPACITY tasks"

# Scale IN: cada viernes a las 22:00 UTC (volver a capacidad normal)
aws application-autoscaling put-scheduled-action \
  --service-namespace ecs \
  --resource-id "service/$CLUSTER/$SERVICIO_API" \
  --scalable-dimension ecs:service:DesiredCount \
  --scheduled-action-name shopapi-black-friday-scale-in \
  --schedule "cron($BF_HORA_FIN 0 ? * FRI *)" \
  --scalable-target-action "MinCapacity=$API_MIN_CAPACITY,MaxCapacity=$API_MAX_CAPACITY" \
  --region "$REGION"

log_info "Scheduled Action SCALE IN:  viernes ${BF_HORA_FIN}:00 UTC → min=$API_MIN_CAPACITY tasks"

# -----------------------------------------------------------------------------
# Paso 5: Verificar configuracion
# -----------------------------------------------------------------------------
log_paso "Paso 5/5 — Verificando configuracion de Auto Scaling..."

echo ""
echo "--- Scalable Target ---"
aws application-autoscaling describe-scalable-targets \
  --service-namespace ecs \
  --resource-ids "service/$CLUSTER/$SERVICIO_API" \
  --query "ScalableTargets[0].{Min:MinCapacity,Max:MaxCapacity,Dim:ScalableDimension}" \
  --output table \
  --region "$REGION"

echo ""
echo "--- Politicas de Escalado ---"
aws application-autoscaling describe-scaling-policies \
  --service-namespace ecs \
  --resource-id "service/$CLUSTER/$SERVICIO_API" \
  --query "ScalingPolicies[*].{Nombre:PolicyName,Tipo:PolicyType}" \
  --output table \
  --region "$REGION"

echo ""
echo "--- Scheduled Actions ---"
aws application-autoscaling describe-scheduled-actions \
  --service-namespace ecs \
  --resource-id "service/$CLUSTER/$SERVICIO_API" \
  --query "ScheduledActions[*].{Nombre:ScheduledActionName,Schedule:Schedule}" \
  --output table \
  --region "$REGION"

# -----------------------------------------------------------------------------
# Resumen
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  AUTO SCALING DE LA API CONFIGURADO"
echo "============================================================"
echo ""
echo "  Mecanismo 1 — Target Tracking (principal):"
echo "    Metrica:  ALBRequestCountPerTarget"
echo "    Target:   $ALB_TARGET_VALUE req/min por task"
echo "    Scale in: tras 300s de cooldown"
echo ""
echo "  Mecanismo 2 — Step Scaling (guardrail CPU):"
echo "    Alarma:   CPU > ${CPU_THRESHOLD_HIGH}% durante 2 min"
echo "    CPU 80%+: +1 task | CPU 100%+: +3 tasks"
echo ""
echo "  Mecanismo 3 — Scheduled (Black Friday):"
echo "    Scale out: Viernes ${BF_HORA_INICIO}:00 UTC → min $BF_MIN_CAPACITY tasks"
echo "    Scale in:  Viernes ${BF_HORA_FIN}:00 UTC → volver a min $API_MIN_CAPACITY tasks"
echo ""
echo "============================================================"
echo ""
echo "Para lanzar el stress test:"
echo "  bash 02-autoscaling-api.sh --stress-test"
echo ""
echo "Para monitorear el escalado:"
echo "  bash 02-autoscaling-api.sh --monitor"
echo ""
echo "Siguiente paso: bash 03-sqs-workers.sh"
