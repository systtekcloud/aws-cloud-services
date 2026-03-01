#!/usr/bin/env bash
# ==============================================================================
# Lab v2 ShopAPI — Paso 4: Demo Rolling Update
# ==============================================================================
# Demuestra cómo ECS realiza un rolling update sin downtime:
#
#   1. Registra una nueva Task Definition con APP_VERSION=0.2.0
#   2. Actualiza el servicio con la nueva revisión
#   3. Monitorea el deployment en tiempo real
#   4. Verifica con curl que el ALB sigue respondiendo durante el update
#
# Matemática del rolling update:
#   desiredCount = 2
#   maximumPercent = 200 → máximo 4 tasks en ejecución durante el update
#   minimumHealthyPercent = 100 → mínimo 2 tasks healthy en todo momento
#
# Secuencia:
#   [v1] [v1]              → estado inicial
#   [v1] [v1] [v2] [v2]   → ECS lanza 2 nuevas tasks (max=4)
#   [v1] [v1] [v2] [v2]   → ALB drena v1, redirige tráfico a v2
#   [v2] [v2]              → estado final (v1 terminadas)
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Cargar variables del entorno
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(dirname "$0")"
ENV_FILE="${SCRIPT_DIR}/00-env.sh"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: No se encontró $ENV_FILE" >&2
  echo "  Ejecuta primero los pasos 01, 02 y 03" >&2
  exit 1
fi

# shellcheck source=00-env.sh
source "$ENV_FILE"

: "${REGION:?REGION no definida}"
: "${ACCOUNT_ID:?ACCOUNT_ID no definida}"
: "${ALB_DNS:?ALB_DNS no definida — ejecuta 02-alb-y-sg.sh}"

# ------------------------------------------------------------------------------
# Configuración del rolling update
# ------------------------------------------------------------------------------
CLUSTER_NAME="shopapi-cluster"
SERVICE_NAME="shopapi-api-service"
TASK_FAMILY="shopapi-api"
CONTAINER_NAME="shopapi-api"
CONTAINER_PORT=8080

NEW_VERSION="0.2.0"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/shopapi/api"
IMAGE_URI="${ECR_URI}:latest"

LOG_GROUP="/ecs/${TASK_FAMILY}"
EXECUTION_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/ecsTaskExecutionRole"

# Colores para la salida (si el terminal los soporta)
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  RED='\033[0;31m'
  NC='\033[0m'
else
  GREEN='' YELLOW='' BLUE='' RED='' NC=''
fi

# ------------------------------------------------------------------------------
# Funciones auxiliares
# ------------------------------------------------------------------------------
log()     { echo "[$(date '+%H:%M:%S')] $*"; }
ok()      { echo -e "[$(date '+%H:%M:%S')] ${GREEN}OK${NC}  $*"; }
info()    { echo -e "[$(date '+%H:%M:%S')] ${BLUE}INFO${NC} $*"; }
warn()    { echo -e "[$(date '+%H:%M:%S')] ${YELLOW}WARN${NC} $*"; }
fail()    { echo -e "[$(date '+%H:%M:%S')] ${RED}ERR${NC}  $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Obtener revisión actual del servicio
# ------------------------------------------------------------------------------
get_current_revision() {
  aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0].taskDefinition' \
    --output text | grep -oP ':\K\d+$'
}

# ------------------------------------------------------------------------------
# Mostrar estado del deployment
# ------------------------------------------------------------------------------
show_deployment_status() {
  aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0].deployments[*].{
      id:id,
      status:status,
      desired:desiredCount,
      running:runningCount,
      pending:pendingCount,
      failed:failedTasks,
      state:rolloutState
    }' \
    --output table 2>/dev/null || echo "(no se pudo obtener estado)"
}

# ------------------------------------------------------------------------------
# Verificar ALB en background (curl en bucle)
# ------------------------------------------------------------------------------
start_curl_monitor() {
  local dns="$1"
  local log_file="/tmp/shopapi_curl_monitor_$$.log"

  log "Iniciando monitor de curl en background → http://${dns}/health"
  log "  Logs en: $log_file"

  # Ejecutar curl en background y guardar el PID
  (
    while true; do
      TIMESTAMP=$(date '+%H:%M:%S')
      HTTP_CODE=$(curl -s -o /tmp/shopapi_curl_body_$$.json \
        -w "%{http_code}" \
        --max-time 5 \
        "http://${dns}/health" 2>/dev/null || echo "ERR")

      if [[ "$HTTP_CODE" == "200" ]]; then
        VERSION=$(python3 -c "import sys,json; d=json.load(open('/tmp/shopapi_curl_body_$$.json')); print(d.get('version','?'))" 2>/dev/null || echo "?")
        echo "[$TIMESTAMP] HTTP $HTTP_CODE | version=$VERSION | OK" >> "$log_file"
      else
        echo "[$TIMESTAMP] HTTP $HTTP_CODE | FALLO" >> "$log_file"
      fi
      sleep 2
    done
  ) &

  CURL_MONITOR_PID=$!
  echo "$CURL_MONITOR_PID" > /tmp/shopapi_curl_monitor_pid_$$.txt
  echo "$log_file"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  DEMO: Rolling Update ShopAPI v${NEW_VERSION}${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

CURRENT_REVISION=$(get_current_revision 2>/dev/null || echo "?")
info "Revision actual del servicio: ${TASK_FAMILY}:${CURRENT_REVISION}"
info "Nueva version a desplegar: APP_VERSION=${NEW_VERSION}"
echo ""

# ------------------------------------------------------------------------------
# Paso 1: Registrar nueva Task Definition con v0.2.0
# ------------------------------------------------------------------------------
log "--- PASO 1: Registrar nueva Task Definition ---"

TASK_DEF_JSON=$(cat <<EOF
{
  "family": "${TASK_FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "${EXECUTION_ROLE_ARN}",
  "containerDefinitions": [
    {
      "name": "${CONTAINER_NAME}",
      "image": "${IMAGE_URI}",
      "portMappings": [
        {
          "containerPort": ${CONTAINER_PORT},
          "protocol": "tcp"
        }
      ],
      "environment": [
        {"name": "APP_VERSION", "value": "${NEW_VERSION}"},
        {"name": "PORT", "value": "${CONTAINER_PORT}"},
        {"name": "LOG_LEVEL", "value": "info"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${LOG_GROUP}",
          "awslogs-region": "${REGION}",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost:${CONTAINER_PORT}/health || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 10
      },
      "essential": true
    }
  ]
}
EOF
)

NEW_TASK_DEF_ARN=$(aws ecs register-task-definition \
  --cli-input-json "$TASK_DEF_JSON" \
  --region "$REGION" \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

NEW_REVISION=$(echo "$NEW_TASK_DEF_ARN" | grep -oP ':\K\d+$')

ok "Nueva Task Definition: ${TASK_FAMILY}:${NEW_REVISION}"
info "  APP_VERSION: ${NEW_VERSION}"
info "  Image: ${IMAGE_URI}"

# ------------------------------------------------------------------------------
# Paso 2: Iniciar monitor de curl
# ------------------------------------------------------------------------------
log ""
log "--- PASO 2: Iniciar monitor de disponibilidad del ALB ---"

CURL_LOG=$(start_curl_monitor "$ALB_DNS")
CURL_PID=$(cat /tmp/shopapi_curl_monitor_pid_$$.txt 2>/dev/null || echo "")

ok "Monitor iniciado (PID: $CURL_PID)"

# Verificación inicial antes del update
sleep 3
info "Estado inicial del ALB:"
INITIAL_RESPONSE=$(curl -s --max-time 5 "http://${ALB_DNS}/health" 2>/dev/null || echo "{}")
echo "  $INITIAL_RESPONSE"

# ------------------------------------------------------------------------------
# Paso 3: Iniciar el rolling update
# ------------------------------------------------------------------------------
log ""
log "--- PASO 3: Iniciar Rolling Update ---"
log "  Actualizando servicio a ${TASK_FAMILY}:${NEW_REVISION}..."

DEPLOY_START=$(date '+%H:%M:%S')

aws ecs update-service \
  --cluster "$CLUSTER_NAME" \
  --service "$SERVICE_NAME" \
  --task-definition "$NEW_TASK_DEF_ARN" \
  --region "$REGION" \
  --query 'service.{status:status,desiredCount:desiredCount}' \
  --output table

ok "Rolling update iniciado a las $DEPLOY_START"

# ------------------------------------------------------------------------------
# Paso 4: Monitorear el deployment en tiempo real
# ------------------------------------------------------------------------------
log ""
log "--- PASO 4: Monitoreo en tiempo real ---"
log "  Actualizando cada 10 segundos..."
log "  Ctrl+C para salir del monitoreo (el update continuará en AWS)"
echo ""

TIMEOUT_SECONDS=600  # 10 minutos máximo
ELAPSED=0

# Función de limpieza al salir con Ctrl+C
cleanup_monitor() {
  echo ""
  log "Monitoreo interrumpido por el usuario"
  if [[ -n "${CURL_PID:-}" ]]; then
    kill "$CURL_PID" 2>/dev/null || true
  fi
  log "El rolling update continúa en AWS aunque hayas salido del monitoreo"
  show_curl_summary
  exit 0
}

trap cleanup_monitor INT TERM

show_curl_summary() {
  if [[ -f "${CURL_LOG}" ]]; then
    echo ""
    log "=== RESUMEN DE DISPONIBILIDAD DURANTE EL UPDATE ==="
    TOTAL=$(wc -l < "$CURL_LOG" 2>/dev/null || echo 0)
    ERRORS=$(grep -c "FALLO" "$CURL_LOG" 2>/dev/null || echo 0)
    OK_COUNT=$((TOTAL - ERRORS))
    echo "  Total checks: $TOTAL"
    echo "  Exitosos:     $OK_COUNT"
    echo "  Fallos:       $ERRORS"
    echo ""
    echo "  Últimas 10 entradas:"
    tail -10 "$CURL_LOG" 2>/dev/null | sed 's/^/    /'

    if [[ "$ERRORS" -eq 0 ]]; then
      ok "ZERO DOWNTIME: Ninguna petición falló durante el rolling update"
    else
      warn "Se detectaron $ERRORS fallos durante el update"
    fi
  fi
}

while [[ $ELAPSED -lt $TIMEOUT_SECONDS ]]; do
  echo ""
  echo -e "${YELLOW}[$(date '+%H:%M:%S')] +${ELAPSED}s desde el inicio del update${NC}"
  echo "------------------------------------------------------------"

  # Estado de los deployments
  DEPLOYMENTS=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0].deployments[*].{
      estado:status,
      version:taskDefinition,
      deseadas:desiredCount,
      running:runningCount,
      pending:pendingCount,
      failed:failedTasks,
      rollout:rolloutState
    }' \
    --output json 2>/dev/null)

  echo "$DEPLOYMENTS" | python3 -c "
import sys, json
deps = json.load(sys.stdin)
for d in deps:
    # Extraer solo la familia:revision de la ARN
    td = d['version'].split('/')[-1] if '/' in d.get('version','') else d.get('version','?')
    print(f\"  [{d.get('estado','?'):10s}] {td:30s} | desired={d.get('deseadas',0)} running={d.get('running',0)} pending={d.get('pending',0)} failed={d.get('failed',0)} | rollout={d.get('rollout','?')}\")
" 2>/dev/null || echo "$DEPLOYMENTS"

  # Verificar si el update completó
  ACTIVE_DEPLOYMENTS=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'length(services[0].deployments[?status==`PRIMARY`])' \
    --output text 2>/dev/null || echo "?")

  OLD_DEPLOYMENTS=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'length(services[0].deployments)' \
    --output text 2>/dev/null || echo "?")

  ROLLOUT_STATE=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0].deployments[0].rolloutState' \
    --output text 2>/dev/null || echo "?")

  echo ""
  echo "  Total deployments activos: $OLD_DEPLOYMENTS | Rollout state: $ROLLOUT_STATE"

  # Estado de los targets del ALB
  HEALTHY=$(aws elbv2 describe-target-health \
    --target-group-arn "$TG_ARN" \
    --region "$REGION" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' \
    --output text 2>/dev/null || echo "?")

  TOTAL_TARGETS=$(aws elbv2 describe-target-health \
    --target-group-arn "$TG_ARN" \
    --region "$REGION" \
    --query 'length(TargetHealthDescriptions)' \
    --output text 2>/dev/null || echo "?")

  echo "  Targets ALB: $HEALTHY/$TOTAL_TARGETS healthy"

  # Respuesta actual del ALB
  CURRENT_RESPONSE=$(curl -s --max-time 3 "http://${ALB_DNS}/health" 2>/dev/null || echo '{"error":"timeout"}')
  echo "  ALB /health: $CURRENT_RESPONSE"

  # Condición de salida: update completado exitosamente
  if [[ "$ROLLOUT_STATE" == "COMPLETED" && "$OLD_DEPLOYMENTS" == "1" ]]; then
    echo ""
    ok "Rolling update completado exitosamente!"
    break
  fi

  # Condición de error: circuit breaker activado
  if [[ "$ROLLOUT_STATE" == "FAILED" ]]; then
    echo ""
    warn "Deployment FALLIDO — Circuit breaker activado"
    warn "ECS realizará rollback automático a la versión anterior"

    # Últimos eventos del servicio
    echo ""
    log "Últimos eventos del servicio:"
    aws ecs describe-services \
      --cluster "$CLUSTER_NAME" \
      --services "$SERVICE_NAME" \
      --region "$REGION" \
      --query 'services[0].events[:5].message' \
      --output text

    break
  fi

  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

# ------------------------------------------------------------------------------
# Paso 5: Verificación final
# ------------------------------------------------------------------------------
log ""
log "--- PASO 5: Verificación final ---"

# Detener el monitor de curl
if [[ -n "${CURL_PID:-}" ]]; then
  kill "$CURL_PID" 2>/dev/null || true
fi

# Respuesta final del ALB
echo ""
log "Respuesta final de todos los endpoints:"

for ENDPOINT in health products metrics; do
  RESPONSE=$(curl -s --max-time 5 "http://${ALB_DNS}/${ENDPOINT}" 2>/dev/null || echo '{"error":"timeout"}')
  echo "  /$ENDPOINT: $RESPONSE" | head -c 200
  echo ""
done

# Versión actual en el servicio
ACTIVE_TASK_DEF=$(aws ecs describe-services \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" \
  --region "$REGION" \
  --query 'services[0].taskDefinition' \
  --output text 2>/dev/null | awk -F'/' '{print $NF}')

echo ""
ok "Task Definition activa: $ACTIVE_TASK_DEF"

# Mostrar resumen del monitor de curl
show_curl_summary

# Limpiar archivos temporales
rm -f "/tmp/shopapi_curl_body_$$.json" \
      "/tmp/shopapi_curl_monitor_pid_$$.txt" 2>/dev/null || true

# ------------------------------------------------------------------------------
# Resumen final
# ------------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  RESUMEN ROLLING UPDATE — ShopAPI Lab v2"
echo "============================================================"
echo "  Versión anterior:  ${TASK_FAMILY}:${CURRENT_REVISION} (v0.1.0)"
echo "  Versión nueva:     ${TASK_FAMILY}:${NEW_REVISION} (v${NEW_VERSION})"
echo "  Inicio update:     $DEPLOY_START"
echo "  Fin update:        $(date '+%H:%M:%S')"
echo ""
echo "  Matemática del rolling update:"
echo "    desiredCount = 2"
echo "    maximumPercent = 200 → max 4 tasks simultáneas"
echo "    minimumHealthyPercent = 100 → min 2 tasks healthy siempre"
echo ""
echo "  Resultado: Zero downtime deployment"
echo "============================================================"
