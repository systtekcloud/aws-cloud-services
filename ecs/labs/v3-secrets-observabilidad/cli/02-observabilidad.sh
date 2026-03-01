#!/usr/bin/env bash
# =============================================================================
# Lab v3 — Fase A3 y A4: Container Insights y CloudWatch Alarms
# ShopAPI — ECS Fargate
#
# Que hace este script:
#   1. Habilita Container Insights en el cluster
#   2. Crea SNS topic para notificaciones de alarmas
#   3. Crea 3 CloudWatch Alarms (5xx rate, latencia P99, tareas unhealthy)
#   4. Crea un CloudWatch Dashboard básico
# =============================================================================
set -euo pipefail

# ─── Variables ───────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-eu-west-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_NAME="shopapi-cluster"
SERVICE_NAME="shopapi-service"
ALB_NAME="shopapi-alb"
SNS_TOPIC_NAME="shopapi-alertas"
NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL:-ops@shopapi.internal}"

echo "========================================================"
echo "  Lab v3 — Container Insights y CloudWatch Alarms"
echo "  Cuenta: ${ACCOUNT_ID}"
echo "  Region: ${AWS_REGION}"
echo "========================================================"
echo ""

# =============================================================================
# A3 — CONTAINER INSIGHTS
# =============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "FASE A3: Habilitando Container Insights"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

aws ecs update-cluster-settings \
  --cluster "${CLUSTER_NAME}" \
  --settings name=containerInsights,value=enabled \
  --region "${AWS_REGION}" \
  --query 'cluster.{Nombre:clusterName,Configuracion:settings}' \
  --output json

echo ""
echo "[OK] Container Insights habilitado en el cluster '${CLUSTER_NAME}'."
echo ""
echo "[INFO] Métricas disponibles en CloudWatch namespace 'ECS/ContainerInsights':"
echo "  - CpuUtilized / CpuReserved       (en vCPU)"
echo "  - MemoryUtilized / MemoryReserved  (en MB)"
echo "  - NetworkRxBytes / NetworkTxBytes  (por red)"
echo "  - RunningTaskCount / PendingTaskCount"
echo "  - TaskCount (total tareas del servicio)"
echo ""
echo "[INFO] Dónde ver las métricas:"
echo "  Consola → CloudWatch → Container Insights → ECS Services → ${CLUSTER_NAME}"
echo "  O bien: CloudWatch → Metrics → ECS/ContainerInsights"

# Verificar que se habilitó correctamente
CONTAINER_INSIGHTS_STATUS=$(aws ecs describe-clusters \
  --clusters "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --query 'clusters[0].settings[?name==`containerInsights`].value' \
  --output text)

if [[ "${CONTAINER_INSIGHTS_STATUS}" == "enabled" ]]; then
  echo ""
  echo "[OK] Verificado: Container Insights = enabled"
else
  echo ""
  echo "[WARN] Container Insights no aparece como 'enabled'. Estado: ${CONTAINER_INSIGHTS_STATUS}"
fi

# =============================================================================
# A4 — SNS TOPIC PARA NOTIFICACIONES
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "FASE A4a: Creando SNS Topic para alertas"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Crear el SNS topic (idempotente: si ya existe devuelve el ARN existente)
SNS_TOPIC_ARN=$(aws sns create-topic \
  --name "${SNS_TOPIC_NAME}" \
  --region "${AWS_REGION}" \
  --query 'TopicArn' \
  --output text)

echo "[OK] SNS Topic creado/obtenido: ${SNS_TOPIC_ARN}"

# Suscribir email para notificaciones
# (el usuario recibirá un email de confirmación que debe aceptar)
echo ""
echo "[INFO] Suscribiendo email '${NOTIFICATION_EMAIL}' al topic..."
echo "       (Recibirás un email de confirmación — debes aceptarlo para activar las alertas)"
aws sns subscribe \
  --topic-arn "${SNS_TOPIC_ARN}" \
  --protocol email \
  --notification-endpoint "${NOTIFICATION_EMAIL}" \
  --region "${AWS_REGION}" \
  --query 'SubscriptionArn' \
  --output text

echo ""
echo "[INFO] Para cambiar el email, ejecuta con: NOTIFICATION_EMAIL=tu@email.com ./02-observabilidad.sh"

# =============================================================================
# A4 — OBTENER DIMENSIONES DEL ALB
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "FASE A4b: Obteniendo dimensiones del ALB para las alarmas"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Verificar que el ALB existe
if ! aws elbv2 describe-load-balancers \
    --names "${ALB_NAME}" \
    --region "${AWS_REGION}" \
    --output text > /dev/null 2>&1; then
  echo "[ERROR] No se encontró el ALB '${ALB_NAME}'."
  echo "        Verifica que el Lab v2 está completado y el ALB existe."
  exit 1
fi

ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${ALB_NAME}" \
  --region "${AWS_REGION}" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

# La dimensión CloudWatch para el ALB es la parte del ARN después de "loadbalancer/"
# Ejemplo: app/shopapi-alb/1234567890abcdef
ALB_DIMENSION=$(echo "${ALB_ARN}" | sed 's|.*:loadbalancer/||')

echo "[INFO] ALB ARN: ${ALB_ARN}"
echo "[INFO] ALB Dimension (CloudWatch): ${ALB_DIMENSION}"

# Obtener el Target Group para métricas más específicas
TG_ARN=$(aws elbv2 describe-target-groups \
  --load-balancer-arn "${ALB_ARN}" \
  --region "${AWS_REGION}" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text 2>/dev/null || echo "")

if [[ -n "${TG_ARN}" && "${TG_ARN}" != "None" ]]; then
  TG_DIMENSION=$(echo "${TG_ARN}" | sed 's|.*:targetgroup/|targetgroup/|')
  echo "[INFO] Target Group Dimension: ${TG_DIMENSION}"
else
  echo "[WARN] No se encontró Target Group para el ALB. Las alarmas usarán solo la dimensión del ALB."
  TG_DIMENSION=""
fi

# =============================================================================
# A4 — CLOUDWATCH ALARM 1: Errores 5xx
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "FASE A4c: Creando Alarma 1 — Errores HTTP 5xx"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Concepto: HTTPCode_ELB_5XX_Count cuenta errores generados por el ALB"
echo "  (timeout de backend, error de conexión, etc.)"
echo "  HTTPCode_Target_5XX_Count cuenta errores devueltos por los contenedores."
echo "  Monitorizamos ambos para cobertura completa."
echo ""

# Alarma para errores 5xx del ALB (generados por el propio ALB)
aws cloudwatch put-metric-alarm \
  --alarm-name "shopapi-alb-5xx-rate" \
  --alarm-description "Errores HTTP 5xx del ALB superan 5 en 2 minutos consecutivos. Indica problemas en los contenedores o el ALB." \
  --namespace "AWS/ApplicationELB" \
  --metric-name "HTTPCode_ELB_5XX_Count" \
  --dimensions Name=LoadBalancer,Value="${ALB_DIMENSION}" \
  --statistic Sum \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 5 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "${SNS_TOPIC_ARN}" \
  --ok-actions "${SNS_TOPIC_ARN}" \
  --region "${AWS_REGION}"

echo "[OK] Alarma 'shopapi-alb-5xx-rate' creada."
echo "     Umbral: >5 errores 5xx en 2 periodos de 60s → ALARM"
echo "     Métrica: AWS/ApplicationELB > HTTPCode_ELB_5XX_Count"

# =============================================================================
# A4 — CLOUDWATCH ALARM 2: Latencia P99
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "FASE A4d: Creando Alarma 2 — Latencia P99 > 1 segundo"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Concepto: P99 significa que el 99% de las peticiones responden"
echo "  en ese tiempo o menos. Es más representativo que la media"
echo "  para detectar cuellos de botella que afectan a usuarios reales."
echo ""

aws cloudwatch put-metric-alarm \
  --alarm-name "shopapi-alb-latencia-p99" \
  --alarm-description "Latencia P99 del ALB supera 1 segundo durante 3 minutos consecutivos. Indica degradacion de rendimiento." \
  --namespace "AWS/ApplicationELB" \
  --metric-name "TargetResponseTime" \
  --dimensions Name=LoadBalancer,Value="${ALB_DIMENSION}" \
  --extended-statistic "p99" \
  --period 60 \
  --evaluation-periods 3 \
  --threshold 1.0 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "${SNS_TOPIC_ARN}" \
  --ok-actions "${SNS_TOPIC_ARN}" \
  --region "${AWS_REGION}"

echo "[OK] Alarma 'shopapi-alb-latencia-p99' creada."
echo "     Umbral: P99 > 1.0 segundos en 3 periodos de 60s → ALARM"
echo "     Métrica: AWS/ApplicationELB > TargetResponseTime (p99)"

# =============================================================================
# A4 — CLOUDWATCH ALARM 3: Tareas ECS por debajo del desired count
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "FASE A4e: Creando Alarma 3 — Tareas ECS por debajo del deseado"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  IMPORTANTE: Esta alarma requiere Container Insights habilitado."
echo "  La métrica RunningTaskCount solo existe en ECS/ContainerInsights."
echo "  El desired count configurado es 2 (del Lab v2)."
echo ""

aws cloudwatch put-metric-alarm \
  --alarm-name "shopapi-ecs-tareas-unhealthy" \
  --alarm-description "El numero de tareas ECS en ejecucion es menor que 2 (desired count). Indica tareas cayendo o no arrancando." \
  --namespace "ECS/ContainerInsights" \
  --metric-name "RunningTaskCount" \
  --dimensions \
    Name=ClusterName,Value="${CLUSTER_NAME}" \
    Name=ServiceName,Value="${SERVICE_NAME}" \
  --statistic Average \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 2 \
  --comparison-operator LessThanThreshold \
  --treat-missing-data breaching \
  --alarm-actions "${SNS_TOPIC_ARN}" \
  --ok-actions "${SNS_TOPIC_ARN}" \
  --region "${AWS_REGION}"

echo "[OK] Alarma 'shopapi-ecs-tareas-unhealthy' creada."
echo "     Umbral: RunningTaskCount < 2 en 2 periodos de 60s → ALARM"
echo "     Métrica: ECS/ContainerInsights > RunningTaskCount"
echo "     treat-missing-data: breaching (si no hay datos → ALARM)"

# =============================================================================
# CLOUDWATCH DASHBOARD
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Creando CloudWatch Dashboard: shopapi-overview"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

DASHBOARD_BODY=$(cat << EOF
{
  "widgets": [
    {
      "type": "alarm",
      "x": 0, "y": 0, "width": 24, "height": 2,
      "properties": {
        "title": "Estado de Alarmas ShopAPI",
        "alarms": [
          "arn:aws:cloudwatch:${AWS_REGION}:${ACCOUNT_ID}:alarm:shopapi-alb-5xx-rate",
          "arn:aws:cloudwatch:${AWS_REGION}:${ACCOUNT_ID}:alarm:shopapi-alb-latencia-p99",
          "arn:aws:cloudwatch:${AWS_REGION}:${ACCOUNT_ID}:alarm:shopapi-ecs-tareas-unhealthy"
        ]
      }
    },
    {
      "type": "metric",
      "x": 0, "y": 2, "width": 12, "height": 6,
      "properties": {
        "title": "Latencia ALB (P50, P95, P99)",
        "metrics": [
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", "${ALB_DIMENSION}", {"stat": "p50", "label": "P50"}],
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", "${ALB_DIMENSION}", {"stat": "p95", "label": "P95"}],
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", "${ALB_DIMENSION}", {"stat": "p99", "label": "P99"}]
        ],
        "view": "timeSeries",
        "period": 60,
        "region": "${AWS_REGION}",
        "yAxis": {"left": {"label": "Segundos", "min": 0}}
      }
    },
    {
      "type": "metric",
      "x": 12, "y": 2, "width": 12, "height": 6,
      "properties": {
        "title": "Errores HTTP (4xx y 5xx)",
        "metrics": [
          ["AWS/ApplicationELB", "HTTPCode_ELB_4XX_Count", "LoadBalancer", "${ALB_DIMENSION}", {"stat": "Sum", "label": "4xx (ALB)"}],
          ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", "${ALB_DIMENSION}", {"stat": "Sum", "label": "5xx (ALB)"}],
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", "${ALB_DIMENSION}", {"stat": "Sum", "label": "5xx (Target)"}]
        ],
        "view": "timeSeries",
        "period": 60,
        "region": "${AWS_REGION}"
      }
    },
    {
      "type": "metric",
      "x": 0, "y": 8, "width": 12, "height": 6,
      "properties": {
        "title": "Tareas ECS en Ejecucion",
        "metrics": [
          ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", "${CLUSTER_NAME}", "ServiceName", "${SERVICE_NAME}", {"stat": "Average", "label": "Running"}],
          ["ECS/ContainerInsights", "PendingTaskCount", "ClusterName", "${CLUSTER_NAME}", "ServiceName", "${SERVICE_NAME}", {"stat": "Average", "label": "Pending"}]
        ],
        "view": "timeSeries",
        "period": 60,
        "region": "${AWS_REGION}",
        "annotations": {
          "horizontal": [{"value": 2, "label": "Desired Count", "color": "#ff7f0e"}]
        }
      }
    },
    {
      "type": "metric",
      "x": 12, "y": 8, "width": 12, "height": 6,
      "properties": {
        "title": "CPU y Memoria ECS (Container Insights)",
        "metrics": [
          ["ECS/ContainerInsights", "CpuUtilized", "ClusterName", "${CLUSTER_NAME}", "ServiceName", "${SERVICE_NAME}", {"stat": "Average", "label": "CPU Utilizada (vCPU)"}],
          ["ECS/ContainerInsights", "MemoryUtilized", "ClusterName", "${CLUSTER_NAME}", "ServiceName", "${SERVICE_NAME}", {"stat": "Average", "label": "Memoria Utilizada (MB)"}]
        ],
        "view": "timeSeries",
        "period": 60,
        "region": "${AWS_REGION}"
      }
    },
    {
      "type": "metric",
      "x": 0, "y": 14, "width": 24, "height": 6,
      "properties": {
        "title": "Peticiones totales ALB",
        "metrics": [
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", "${ALB_DIMENSION}", {"stat": "Sum", "label": "Peticiones totales"}],
          ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", "${ALB_DIMENSION}", {"stat": "Average", "label": "Hosts saludables"}]
        ],
        "view": "timeSeries",
        "period": 60,
        "region": "${AWS_REGION}"
      }
    }
  ]
}
EOF
)

aws cloudwatch put-dashboard \
  --dashboard-name "shopapi-overview" \
  --dashboard-body "${DASHBOARD_BODY}" \
  --region "${AWS_REGION}"

echo "[OK] Dashboard 'shopapi-overview' creado."
echo "     URL: https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#dashboards:name=shopapi-overview"

# =============================================================================
# VERIFICACIÓN FINAL
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "VERIFICACIÓN: Estado de las alarmas creadas"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

sleep 3  # Esperar a que las alarmas se registren

aws cloudwatch describe-alarms \
  --alarm-name-prefix "shopapi-" \
  --region "${AWS_REGION}" \
  --query 'MetricAlarms[*].{
    Nombre:AlarmName,
    Estado:StateValue,
    Motivo:StateReason,
    Metrica:MetricName,
    Namespace:Namespace
  }' \
  --output table

echo ""
echo "  Estado inicial esperado: INSUFFICIENT_DATA (sin datos suficientes aún)"
echo "  Después de ~5 minutos con tráfico debería pasar a OK."

# =============================================================================
# RESUMEN
# =============================================================================
echo ""
echo "========================================================"
echo "  RESUMEN — Recursos de observabilidad creados"
echo "========================================================"
echo ""
echo "  Container Insights: HABILITADO en ${CLUSTER_NAME}"
echo ""
echo "  SNS Topic:"
echo "    ARN: ${SNS_TOPIC_ARN}"
echo "    Email suscrito: ${NOTIFICATION_EMAIL}"
echo "    (Confirma el email de subscripcion para activar alertas)"
echo ""
echo "  CloudWatch Alarms:"
echo "    1. shopapi-alb-5xx-rate      → 5xx > 5 en 2 min"
echo "    2. shopapi-alb-latencia-p99  → P99 > 1s en 3 min"
echo "    3. shopapi-ecs-tareas-unhealthy → RunningTasks < 2"
echo ""
echo "  CloudWatch Dashboard:"
echo "    shopapi-overview"
echo ""
echo "  Próximo paso: registrar la nueva Task Definition"
echo "  Ejecutar: 04-update-service.sh"
echo "========================================================"

export SNS_TOPIC_ARN
echo ""
echo "# Variable exportada para scripts posteriores:"
echo "export SNS_TOPIC_ARN='${SNS_TOPIC_ARN}'"
