#!/usr/bin/env bash
# ==============================================================================
# Lab v2 ShopAPI — Paso 3: Crear ECS Service con ALB
# ==============================================================================
# Requiere haber ejecutado 01-vpc-networking.sh y 02-alb-y-sg.sh
#
# Crea:
#   - Task Definition actualizada con imagen ECR y configuración de logging
#   - ECS Service con:
#       desiredCount: 2
#       launchType: FARGATE
#       networkConfiguration: subnets privadas + Task SG
#       loadBalancers: Target Group del ALB
#       healthCheckGracePeriodSeconds: 60
#       deploymentConfiguration: maximumPercent=200, minimumHealthyPercent=100
#       deploymentCircuitBreaker: enable=true, rollback=true
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Cargar variables del entorno
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(dirname "$0")"
ENV_FILE="${SCRIPT_DIR}/00-env.sh"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: No se encontró $ENV_FILE" >&2
  echo "  Ejecuta primero: ./01-vpc-networking.sh && ./02-alb-y-sg.sh" >&2
  exit 1
fi

# shellcheck source=00-env.sh
source "$ENV_FILE"

# Verificar variables mínimas
: "${VPC_ID:?VPC_ID no definida}"
: "${PRIVATE_SUBNET_A:?PRIVATE_SUBNET_A no definida}"
: "${PRIVATE_SUBNET_B:?PRIVATE_SUBNET_B no definida}"
: "${TASK_SG_ID:?TASK_SG_ID no definida — ejecuta 02-alb-y-sg.sh}"
: "${TG_ARN:?TG_ARN no definida — ejecuta 02-alb-y-sg.sh}"
: "${ACCOUNT_ID:?ACCOUNT_ID no definida}"
: "${REGION:?REGION no definida}"

# ------------------------------------------------------------------------------
# Configuracion
# ------------------------------------------------------------------------------
CLUSTER_NAME="shopapi-cluster"
SERVICE_NAME="shopapi-api-service"
TASK_FAMILY="shopapi-api"
CONTAINER_NAME="shopapi-api"
CONTAINER_PORT=8080
APP_VERSION="0.1.0"

ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/shopapi/api"
IMAGE_URI="${ECR_URI}:latest"

# Role ARN para la ejecución de Fargate (debe existir de lab v1)
EXECUTION_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/ecsTaskExecutionRole"

# ------------------------------------------------------------------------------
# Funciones auxiliares
# ------------------------------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] OK  $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ERR $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
log "=========================================="
log " Creando ECS Service con ALB"
log "=========================================="
log "  Cluster:   $CLUSTER_NAME"
log "  Service:   $SERVICE_NAME"
log "  Image:     $IMAGE_URI"
log "  Subnets:   $PRIVATE_SUBNET_A, $PRIVATE_SUBNET_B"
log "  Task SG:   $TASK_SG_ID"
log "  TG ARN:    $TG_ARN"

# ------------------------------------------------------------------------------
# 1. Verificar que la imagen existe en ECR
# ------------------------------------------------------------------------------
log "Verificando imagen en ECR..."

IMAGE_COUNT=$(aws ecr describe-images \
  --repository-name "shopapi/api" \
  --region "$REGION" \
  --query 'length(imageDetails)' \
  --output text 2>/dev/null || echo "0")

if [[ "$IMAGE_COUNT" == "0" ]]; then
  fail "No se encontró la imagen en ECR shopapi/api. Completa el Lab v1 primero."
fi

ok "Imagen encontrada en ECR ($IMAGE_COUNT tags disponibles)"

# ------------------------------------------------------------------------------
# 2. Verificar/crear Log Group en CloudWatch
# ------------------------------------------------------------------------------
LOG_GROUP="/ecs/${TASK_FAMILY}"

log "Creando/verificando log group $LOG_GROUP..."

aws logs create-log-group \
  --log-group-name "$LOG_GROUP" \
  --region "$REGION" 2>/dev/null || true

aws logs put-retention-policy \
  --log-group-name "$LOG_GROUP" \
  --retention-in-days 7 \
  --region "$REGION"

ok "Log group $LOG_GROUP listo (retención: 7 días)"

# ------------------------------------------------------------------------------
# 3. Registrar nueva Task Definition con logging y variables de entorno
# ------------------------------------------------------------------------------
log "Registrando Task Definition $TASK_FAMILY..."

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
        {"name": "APP_VERSION", "value": "${APP_VERSION}"},
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

TASK_DEF_ARN=$(aws ecs register-task-definition \
  --cli-input-json "$TASK_DEF_JSON" \
  --region "$REGION" \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

TASK_DEF_REVISION=$(aws ecs describe-task-definition \
  --task-definition "$TASK_FAMILY" \
  --region "$REGION" \
  --query 'taskDefinition.revision' \
  --output text)

ok "Task Definition registrada: ${TASK_FAMILY}:${TASK_DEF_REVISION}"
ok "  ARN: $TASK_DEF_ARN"

# ------------------------------------------------------------------------------
# 4. Crear el ECS Service
# ------------------------------------------------------------------------------
log "Creando ECS Service $SERVICE_NAME..."
log "  desiredCount: 2"
log "  maximumPercent: 200  (max 4 tasks durante rolling update)"
log "  minimumHealthyPercent: 100  (min 2 tasks siempre healthy)"
log "  healthCheckGracePeriod: 60s"
log "  circuitBreaker: habilitado con rollback automático"

SERVICE_JSON=$(cat <<EOF
{
  "cluster": "${CLUSTER_NAME}",
  "serviceName": "${SERVICE_NAME}",
  "taskDefinition": "${TASK_DEF_ARN}",
  "desiredCount": 2,
  "launchType": "FARGATE",
  "platformVersion": "LATEST",
  "networkConfiguration": {
    "awsvpcConfiguration": {
      "subnets": ["${PRIVATE_SUBNET_A}", "${PRIVATE_SUBNET_B}"],
      "securityGroups": ["${TASK_SG_ID}"],
      "assignPublicIp": "DISABLED"
    }
  },
  "loadBalancers": [
    {
      "targetGroupArn": "${TG_ARN}",
      "containerName": "${CONTAINER_NAME}",
      "containerPort": ${CONTAINER_PORT}
    }
  ],
  "healthCheckGracePeriodSeconds": 60,
  "deploymentConfiguration": {
    "maximumPercent": 200,
    "minimumHealthyPercent": 100,
    "deploymentCircuitBreaker": {
      "enable": true,
      "rollback": true
    }
  },
  "schedulingStrategy": "REPLICA",
  "propagateTags": "SERVICE",
  "tags": [
    {"key": "Name", "value": "${SERVICE_NAME}"},
    {"key": "Lab", "value": "v2"}
  ]
}
EOF
)

SERVICE_ARN=$(aws ecs create-service \
  --cli-input-json "$SERVICE_JSON" \
  --region "$REGION" \
  --query 'service.serviceArn' \
  --output text)

ok "Servicio creado: $SERVICE_ARN"

# Actualizar el archivo de entorno
echo "" >> "$ENV_FILE"
echo "# ECS Service" >> "$ENV_FILE"
echo "export SERVICE_NAME=\"${SERVICE_NAME}\"" >> "$ENV_FILE"
echo "export SERVICE_ARN=\"${SERVICE_ARN}\"" >> "$ENV_FILE"
echo "export TASK_DEF_ARN=\"${TASK_DEF_ARN}\"" >> "$ENV_FILE"
echo "export TASK_DEF_REVISION=\"${TASK_DEF_REVISION}\"" >> "$ENV_FILE"

# ------------------------------------------------------------------------------
# 5. Monitorear el arranque del servicio
# ------------------------------------------------------------------------------
log "Esperando que el servicio alcance el estado estable..."
log "  (puede tardar 2-3 minutos)"
log ""

# Mostrar progreso mientras esperamos
MAX_WAIT=300  # 5 minutos
ELAPSED=0
INTERVAL=15

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  DEPLOYMENT_INFO=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0].deployments[0].{status:status,desired:desiredCount,running:runningCount,pending:pendingCount,failed:failedTasks}' \
    --output json 2>/dev/null)

  STATUS=$(echo "$DEPLOYMENT_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','?'))" 2>/dev/null || echo "?")
  DESIRED=$(echo "$DEPLOYMENT_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('desired',0))" 2>/dev/null || echo "0")
  RUNNING=$(echo "$DEPLOYMENT_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('running',0))" 2>/dev/null || echo "0")
  PENDING=$(echo "$DEPLOYMENT_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('pending',0))" 2>/dev/null || echo "0")
  FAILED=$(echo "$DEPLOYMENT_INFO"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('failed',0))"  2>/dev/null || echo "0")

  log "  Estado: $STATUS | desired=$DESIRED running=$RUNNING pending=$PENDING failed=$FAILED (+${ELAPSED}s)"

  if [[ "$RUNNING" == "$DESIRED" && "$PENDING" == "0" ]]; then
    ok "Servicio estable: $RUNNING/$DESIRED tasks en ejecucion"
    break
  fi

  if [[ "$STATUS" == "FAILED" ]]; then
    fail "Deployment fallido. Revisar eventos: aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].events[:5]'"
  fi

  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
  log "AVISO: Tiempo de espera agotado. El servicio puede seguir iniciándose."
  log "  Verifica manualmente:"
  log "  aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $REGION"
fi

# ------------------------------------------------------------------------------
# 6. Verificar los targets en el ALB
# ------------------------------------------------------------------------------
log "Verificando estado de los targets en el ALB..."

sleep 10  # Dar tiempo al Target Group para registrar los targets

TARGET_HEALTH=$(aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --region "$REGION" \
  --query 'TargetHealthDescriptions[*].{ip:Target.Id,port:Target.Port,state:TargetHealth.State,reason:TargetHealth.Reason}' \
  --output table 2>/dev/null || echo "No se pudo obtener estado de targets")

echo ""
log "Estado de los targets:"
echo "$TARGET_HEALTH"

# ------------------------------------------------------------------------------
# 7. Verificar con curl que el ALB responde
# ------------------------------------------------------------------------------
if [[ -n "${ALB_DNS:-}" ]]; then
  log "Verificando ALB con curl: http://$ALB_DNS/health"
  log "  (si falla, espera 30-60 segundos a que los targets pasen a healthy)"

  # Reintentar hasta 3 veces
  for i in 1 2 3; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time 10 \
      "http://${ALB_DNS}/health" 2>/dev/null || echo "000")

    if [[ "$HTTP_CODE" == "200" ]]; then
      BODY=$(curl -s --max-time 10 "http://${ALB_DNS}/health" 2>/dev/null || echo "{}")
      ok "ALB responde correctamente (HTTP $HTTP_CODE)"
      ok "  Respuesta: $BODY"
      break
    else
      log "  Intento $i/3: HTTP $HTTP_CODE — esperando 20 segundos..."
      sleep 20
    fi
  done
fi

# ------------------------------------------------------------------------------
# 8. Resumen final
# ------------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  RESUMEN ECS SERVICE — ShopAPI Lab v2"
echo "============================================================"
echo "  Cluster:          $CLUSTER_NAME"
echo "  Service:          $SERVICE_NAME"
echo "  Task Definition:  ${TASK_FAMILY}:${TASK_DEF_REVISION}"
echo "  Desired Count:    2"
echo "  Launch Type:      FARGATE"
echo "  Network:          awsvpc (subnets privadas)"
echo ""
echo "  Deployment Config:"
echo "    maximumPercent:        200 (max 4 tasks durante update)"
echo "    minimumHealthyPercent: 100 (min 2 tasks siempre)"
echo "    CircuitBreaker:        habilitado con rollback"
echo ""
if [[ -n "${ALB_DNS:-}" ]]; then
echo "  Endpoints:"
echo "    http://$ALB_DNS/health"
echo "    http://$ALB_DNS/products"
echo "    http://$ALB_DNS/orders"
echo "    http://$ALB_DNS/metrics"
fi
echo ""
echo "  Logs CloudWatch: $LOG_GROUP"
echo "============================================================"
echo ""
echo "  Comandos de monitoreo:"
echo "  aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \\"
echo "    --region $REGION --query 'services[0].{desired:desiredCount,running:runningCount,status:status}'"
echo ""
echo "  aws elbv2 describe-target-health --target-group-arn $TG_ARN --region $REGION"
echo ""
echo "  Siguiente paso (demo rolling update): ./04-rolling-update.sh"
echo "============================================================"
