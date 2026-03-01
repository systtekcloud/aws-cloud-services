#!/usr/bin/env bash
# =============================================================================
# Lab v1 — ShopAPI en ECS Fargate
# Script 02: Cluster ECS, IAM Role, Task Definition y RunTask
#
# Uso:
#   # Minimo requerido:
#   export AWS_ACCOUNT_ID="123456789012"
#   bash cli/02-cluster-y-task.sh
#
#   # Opcional (con subnet/SG especificos):
#   export SUBNET_ID="subnet-xxxxxxxxx"
#   export SG_ID="sg-xxxxxxxxx"
#   bash cli/02-cluster-y-task.sh
#
# Requiere: aws-cli >= 2.0, jq >= 1.6
# El script 01-ecr.sh debe haberse ejecutado antes
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Colores para output legible en terminal
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${YELLOW}========================================${NC}"; \
            echo -e "${YELLOW}  $*${NC}"; \
            echo -e "${YELLOW}========================================${NC}\n"; }

# =============================================================================
# SECCION 1: Configuracion de variables
# =============================================================================
section "Configurando variables de entorno"

# Variables base — obtener Account ID si no esta definido
export AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
export AWS_REGION="${AWS_REGION:-eu-west-1}"
export PROJECT_PREFIX="${PROJECT_PREFIX:-shopapi}"
export IMAGE_TAG="${IMAGE_TAG:-0.1.0}"

# Variables de recursos
export CLUSTER_NAME="${CLUSTER_NAME:-shopapi-cluster}"
export TASK_FAMILY="${TASK_FAMILY:-shopapi-api}"
export EXECUTION_ROLE_NAME="${EXECUTION_ROLE_NAME:-shopapi-execution-role}"
export LOG_GROUP="${LOG_GROUP:-/ecs/shopapi}"
export ECR_REPO_URI="${ECR_REPO_URI:-${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/shopapi/api}"

# Ruta al archivo task-definition.json (relativa al script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_DEF_FILE="${SCRIPT_DIR}/task-definition.json"

info "Configuracion activa:"
echo "  AWS Account ID    : ${AWS_ACCOUNT_ID}"
echo "  AWS Region        : ${AWS_REGION}"
echo "  Cluster Name      : ${CLUSTER_NAME}"
echo "  Task Family       : ${TASK_FAMILY}"
echo "  Execution Role    : ${EXECUTION_ROLE_NAME}"
echo "  Log Group         : ${LOG_GROUP}"
echo "  ECR URI           : ${ECR_REPO_URI}:${IMAGE_TAG}"
echo "  Task Def File     : ${TASK_DEF_FILE}"
echo ""

# Verificar que el archivo task-definition.json existe
if [[ ! -f "${TASK_DEF_FILE}" ]]; then
  error "Archivo task-definition.json no encontrado en: ${TASK_DEF_FILE}"
fi

ok "Archivo task-definition.json encontrado"

# =============================================================================
# SECCION 2: Crear cluster ECS con Container Insights
# =============================================================================
section "Creando cluster ECS"

# Container Insights habilita metricas detalladas en CloudWatch (CPU, memoria, red
# por task/container). Es opcional pero muy recomendado en produccion.
# En este lab lo habilitamos para ver metricas desde el primer momento.

CLUSTER_EXISTS=$(aws ecs describe-clusters \
  --clusters "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --query 'clusters[?status==`ACTIVE`].clusterName' \
  --output text 2>/dev/null || echo "")

if [[ -z "${CLUSTER_EXISTS}" ]]; then
  info "Creando cluster ECS: ${CLUSTER_NAME} ..."

  aws ecs create-cluster \
    --cluster-name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --settings name=containerInsights,value=enabled \
    --configuration executeCommandConfiguration="{logging=DEFAULT}" \
    --tags key=Project,value="${PROJECT_PREFIX}" key=Lab,value=v1

  ok "Cluster creado: ${CLUSTER_NAME}"
else
  warn "El cluster ya existe: ${CLUSTER_EXISTS}"
  ok "Reutilizando cluster existente"
fi

# Verificar estado del cluster
CLUSTER_STATUS=$(aws ecs describe-clusters \
  --clusters "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --query 'clusters[0].status' \
  --output text)

if [[ "${CLUSTER_STATUS}" != "ACTIVE" ]]; then
  error "El cluster no esta en estado ACTIVE. Estado actual: ${CLUSTER_STATUS}"
fi

ok "Estado del cluster: ${CLUSTER_STATUS}"

# =============================================================================
# SECCION 3: Crear IAM Execution Role
# =============================================================================
section "Creando IAM Execution Role"

# El Execution Role es usado por el agente de ECS (no por tu aplicacion) para:
#   1. Descargar la imagen Docker desde ECR (ecr:GetAuthorizationToken, etc.)
#   2. Enviar logs a CloudWatch Logs (logs:CreateLogStream, logs:PutLogEvents)
#
# IMPORTANTE: Distinguir entre:
#   - Execution Role: permisos de infraestructura AWS (este script lo crea)
#   - Task Role: permisos que tendria el codigo de tu app (no necesario en este lab)

ROLE_EXISTS=$(aws iam get-role \
  --role-name "${EXECUTION_ROLE_NAME}" \
  --query 'Role.RoleName' \
  --output text 2>/dev/null || echo "NO_EXISTE")

if [[ "${ROLE_EXISTS}" == "NO_EXISTE" ]]; then
  info "Creando IAM Role: ${EXECUTION_ROLE_NAME} ..."

  # Trust policy: define QUIEN puede asumir este rol
  # En este caso, solo el servicio ecs-tasks.amazonaws.com
  TRUST_POLICY='{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "ecs-tasks.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }'

  aws iam create-role \
    --role-name "${EXECUTION_ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_POLICY}" \
    --description "Rol de ejecucion para tareas ECS Fargate del proyecto ShopAPI" \
    --tags Key=Project,Value="${PROJECT_PREFIX}" Key=Lab,Value=v1

  ok "IAM Role creado: ${EXECUTION_ROLE_NAME}"

  # Adjuntar la politica gestionada por AWS
  # AmazonECSTaskExecutionRolePolicy incluye exactamente los permisos minimos necesarios
  info "Adjuntando politica AmazonECSTaskExecutionRolePolicy ..."
  aws iam attach-role-policy \
    --role-name "${EXECUTION_ROLE_NAME}" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

  ok "Politica adjuntada correctamente"

  # Esperar a que el rol sea propagado en IAM (puede tardar unos segundos)
  info "Esperando propagacion del rol en IAM (10 segundos) ..."
  sleep 10

else
  warn "El IAM Role ya existe: ${ROLE_EXISTS}"
  ok "Reutilizando rol existente"
fi

# Obtener el ARN del rol para usarlo en la Task Definition
export EXECUTION_ROLE_ARN=$(aws iam get-role \
  --role-name "${EXECUTION_ROLE_NAME}" \
  --query 'Role.Arn' \
  --output text)

ok "Execution Role ARN: ${EXECUTION_ROLE_ARN}"

# Verificar politicas adjuntas
info "Politicas adjuntas al rol:"
aws iam list-attached-role-policies \
  --role-name "${EXECUTION_ROLE_NAME}" \
  --query 'AttachedPolicies[*].PolicyName' \
  --output table

# =============================================================================
# SECCION 4: Crear CloudWatch Log Group
# =============================================================================
section "Creando CloudWatch Log Group"

# El log group debe existir ANTES de registrar la Task Definition
# De lo contrario, ECS no podra enviar logs y el task fallara al arrancar

LOG_GROUP_EXISTS=$(aws logs describe-log-groups \
  --log-group-name-prefix "${LOG_GROUP}" \
  --region "${AWS_REGION}" \
  --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName" \
  --output text 2>/dev/null || echo "")

if [[ -z "${LOG_GROUP_EXISTS}" ]]; then
  info "Creando log group: ${LOG_GROUP} ..."

  aws logs create-log-group \
    --log-group-name "${LOG_GROUP}" \
    --region "${AWS_REGION}" \
    --tags Project="${PROJECT_PREFIX}",Lab=v1

  ok "Log group creado: ${LOG_GROUP}"
else
  warn "El log group ya existe: ${LOG_GROUP_EXISTS}"
  ok "Reutilizando log group existente"
fi

# Establecer politica de retencion (30 dias)
# Sin retension, los logs se acumulan indefinidamente y generan costes
info "Configurando retencion de logs a 30 dias ..."
aws logs put-retention-policy \
  --log-group-name "${LOG_GROUP}" \
  --retention-in-days 30 \
  --region "${AWS_REGION}"

ok "Retencion configurada: 30 dias"

# =============================================================================
# SECCION 5: Registrar Task Definition
# =============================================================================
section "Registrando Task Definition"

# La Task Definition es la "plantilla" de lo que ejecuta ECS.
# Sustituimos el placeholder ACCOUNT_ID con el valor real del account.
# Tambien actualizamos el execution role ARN y la imagen con el tag correcto.

info "Procesando task-definition.json ..."

# Crear copia temporal con los valores reales sustituidos
TMP_TASK_DEF="/tmp/shopapi-task-definition-$(date +%s).json"

# Sustituir placeholders con valores reales
sed \
  -e "s|ACCOUNT_ID|${AWS_ACCOUNT_ID}|g" \
  -e "s|EXECUTION_ROLE_ARN_PLACEHOLDER|${EXECUTION_ROLE_ARN}|g" \
  -e "s|IMAGE_TAG_PLACEHOLDER|${IMAGE_TAG}|g" \
  "${TASK_DEF_FILE}" > "${TMP_TASK_DEF}"

ok "Task definition procesada: ${TMP_TASK_DEF}"

# Mostrar resumen de la task definition que se va a registrar
info "Resumen de la Task Definition:"
jq '{
  family: .family,
  requiresCompatibilities: .requiresCompatibilities,
  networkMode: .networkMode,
  cpu: .cpu,
  memory: .memory,
  executionRoleArn: .executionRoleArn,
  container: .containerDefinitions[0] | {
    name: .name,
    image: .image,
    port: .portMappings[0].containerPort,
    logGroup: .logConfiguration.options."awslogs-group"
  }
}' "${TMP_TASK_DEF}" || warn "jq no disponible — mostrando JSON sin formatear"

echo ""
info "Registrando task definition en ECS ..."

# Registrar en ECS — cada registro crea una nueva revision (shopapi-api:1, :2, etc.)
TASK_DEF_ARN=$(aws ecs register-task-definition \
  --cli-input-json "file://${TMP_TASK_DEF}" \
  --region "${AWS_REGION}" \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

ok "Task Definition registrada: ${TASK_DEF_ARN}"

# Obtener la revision registrada
TASK_DEF_REVISION=$(aws ecs describe-task-definition \
  --task-definition "${TASK_FAMILY}" \
  --region "${AWS_REGION}" \
  --query 'taskDefinition.revision' \
  --output text)

ok "Revision activa: ${TASK_FAMILY}:${TASK_DEF_REVISION}"

# Limpiar archivo temporal
rm -f "${TMP_TASK_DEF}"

# =============================================================================
# SECCION 6: Preparar red (subnet y security group)
# =============================================================================
section "Configurando red para RunTask"

# Fargate con networkMode=awsvpc requiere una subnet y un security group
# Si no se proporcionan como variables de entorno, usamos los de la VPC por defecto

if [[ -z "${SUBNET_ID:-}" ]]; then
  info "SUBNET_ID no definido — buscando subnet publica de la VPC por defecto ..."
  SUBNET_ID=$(aws ec2 describe-subnets \
    --filters "Name=default-for-az,Values=true" \
    --region "${AWS_REGION}" \
    --query 'Subnets[0].SubnetId' \
    --output text)

  if [[ -z "${SUBNET_ID}" || "${SUBNET_ID}" == "None" ]]; then
    error "No se encontro ninguna subnet por defecto en ${AWS_REGION}. Exportar SUBNET_ID manualmente."
  fi
  warn "Usando subnet por defecto: ${SUBNET_ID}"
else
  ok "Usando subnet configurada: ${SUBNET_ID}"
fi

if [[ -z "${SG_ID:-}" ]]; then
  info "SG_ID no definido — buscando security group por defecto ..."
  SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=default" \
    --region "${AWS_REGION}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text)

  if [[ -z "${SG_ID}" || "${SG_ID}" == "None" ]]; then
    error "No se encontro security group por defecto. Exportar SG_ID manualmente."
  fi
  warn "Usando security group por defecto: ${SG_ID}"
  warn "ATENCION: El SG por defecto puede no tener el puerto 8080 abierto."
  warn "Para probar el endpoint, abre el puerto 8080 en el SG: ${SG_ID}"
else
  ok "Usando security group configurado: ${SG_ID}"
fi

info "Configuracion de red:"
echo "  Subnet ID       : ${SUBNET_ID}"
echo "  Security Group  : ${SG_ID}"
echo "  Public IP       : ENABLED (necesario para acceder al endpoint)"
echo ""

# =============================================================================
# SECCION 7: Ejecutar RunTask
# =============================================================================
section "Ejecutando RunTask en ECS Fargate"

# RunTask ejecuta UNA instancia de la Task Definition en el cluster.
# En produccion se usaria un ECS Service para mantener N tasks corriendo.
# En este lab (v1) usamos RunTask directamente para entender el concepto basico.

info "Lanzando task en cluster ${CLUSTER_NAME} ..."
info "Task Definition: ${TASK_FAMILY}:${TASK_DEF_REVISION}"
echo ""

TASK_ARN=$(aws ecs run-task \
  --cluster "${CLUSTER_NAME}" \
  --task-definition "${TASK_FAMILY}" \
  --launch-type FARGATE \
  --count 1 \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_ID}],securityGroups=[${SG_ID}],assignPublicIp=ENABLED}" \
  --region "${AWS_REGION}" \
  --tags key=Project,value="${PROJECT_PREFIX}" key=Lab,value=v1 \
  --query 'tasks[0].taskArn' \
  --output text)

if [[ -z "${TASK_ARN}" || "${TASK_ARN}" == "None" ]]; then
  error "RunTask fallo. Revisar permisos IAM y configuracion de red."
fi

ok "Task lanzada: ${TASK_ARN}"

# Extraer el Task ID del ARN (ultima parte del ARN separada por '/')
TASK_ID=$(echo "${TASK_ARN}" | awk -F'/' '{print $NF}')
ok "Task ID: ${TASK_ID}"

# =============================================================================
# SECCION 8: Monitorizar el estado del task
# =============================================================================
section "Monitorizando estado del task"

# El task pasa por estos estados:
#   PROVISIONING -> PENDING -> RUNNING (o STOPPED si hay error)
# Normalmente tarda entre 30 segundos y 2 minutos en llegar a RUNNING

info "Esperando a que el task llegue a estado RUNNING ..."
info "Esto puede tardar 1-3 minutos en Fargate ..."
echo ""

MAX_WAIT_SECONDS=180  # 3 minutos maximos
WAIT_INTERVAL=10      # Comprobar cada 10 segundos
ELAPSED=0
LAST_STATUS=""

while [[ ${ELAPSED} -lt ${MAX_WAIT_SECONDS} ]]; do
  CURRENT_STATUS=$(aws ecs describe-tasks \
    --cluster "${CLUSTER_NAME}" \
    --tasks "${TASK_ARN}" \
    --region "${AWS_REGION}" \
    --query 'tasks[0].lastStatus' \
    --output text 2>/dev/null || echo "UNKNOWN")

  if [[ "${CURRENT_STATUS}" != "${LAST_STATUS}" ]]; then
    info "[${ELAPSED}s] Estado: ${CURRENT_STATUS}"
    LAST_STATUS="${CURRENT_STATUS}"
  fi

  if [[ "${CURRENT_STATUS}" == "RUNNING" ]]; then
    echo ""
    ok "Task en estado RUNNING tras ${ELAPSED} segundos"
    break
  fi

  if [[ "${CURRENT_STATUS}" == "STOPPED" ]]; then
    echo ""
    # Obtener el motivo de la parada para diagnostico
    STOP_REASON=$(aws ecs describe-tasks \
      --cluster "${CLUSTER_NAME}" \
      --tasks "${TASK_ARN}" \
      --region "${AWS_REGION}" \
      --query 'tasks[0].stoppedReason' \
      --output text)
    error "Task se detuvo inesperadamente. Motivo: ${STOP_REASON}"
  fi

  sleep ${WAIT_INTERVAL}
  ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done

if [[ "${LAST_STATUS}" != "RUNNING" ]]; then
  warn "El task no alcanzo RUNNING en ${MAX_WAIT_SECONDS} segundos."
  warn "Estado actual: ${LAST_STATUS}"
  warn "Puedes monitorizarlo manualmente con:"
  echo "  aws ecs describe-tasks --cluster ${CLUSTER_NAME} --tasks ${TASK_ARN} --region ${AWS_REGION}"
fi

# =============================================================================
# SECCION 9: Obtener IP publica del task
# =============================================================================
section "Obteniendo IP publica del task"

# En Fargate con awsvpc, cada task tiene su propia ENI (Elastic Network Interface)
# A traves de la ENI obtenemos la IP publica asignada

# Obtener el ID de la ENI del task
ENI_ID=$(aws ecs describe-tasks \
  --cluster "${CLUSTER_NAME}" \
  --tasks "${TASK_ARN}" \
  --region "${AWS_REGION}" \
  --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" \
  --output text 2>/dev/null || echo "")

if [[ -n "${ENI_ID}" && "${ENI_ID}" != "None" ]]; then
  # Obtener la IP publica desde la ENI
  PUBLIC_IP=$(aws ec2 describe-network-interfaces \
    --network-interface-ids "${ENI_ID}" \
    --region "${AWS_REGION}" \
    --query 'NetworkInterfaces[0].Association.PublicIp' \
    --output text 2>/dev/null || echo "")

  if [[ -n "${PUBLIC_IP}" && "${PUBLIC_IP}" != "None" ]]; then
    ok "IP publica del task: ${PUBLIC_IP}"
    echo ""
    info "Endpoints disponibles (requiere puerto 8080 abierto en SG):"
    echo "  Health  : http://${PUBLIC_IP}:8080/health"
    echo "  Products: http://${PUBLIC_IP}:8080/products"
    echo "  Metrics : http://${PUBLIC_IP}:8080/metrics"
    echo ""

    # Intentar probar el endpoint de health
    info "Probando endpoint /health ..."
    if curl -sf --max-time 5 "http://${PUBLIC_IP}:8080/health" 2>/dev/null; then
      echo ""
      ok "Endpoint /health responde correctamente"
    else
      warn "El endpoint /health no responde desde esta maquina."
      warn "Posibles causas:"
      echo "  1. El SG (${SG_ID}) no permite trafico en puerto 8080 desde tu IP"
      echo "  2. La aplicacion aun esta iniciando (espera 30 segundos y reintenta)"
      echo "  3. La aplicacion no escucha en el puerto 8080"
    fi
  else
    warn "No se pudo obtener la IP publica de la ENI: ${ENI_ID}"
    warn "Puede que assignPublicIp no este habilitado o la subnet sea privada"
  fi
else
  warn "No se pudo obtener el ID de la ENI del task"
  warn "Esto puede ocurrir si el task aun esta en PENDING"
fi

# =============================================================================
# SECCION 10: Ver logs en CloudWatch
# =============================================================================
section "Consultando logs en CloudWatch"

# Esperar un poco para que los logs aparezcan en CloudWatch
info "Esperando 15 segundos para que los logs se propagen a CloudWatch ..."
sleep 15

# El formato del log stream es: {prefix}/{container-name}/{task-id}
# Segun la configuracion en task-definition.json:
#   awslogs-stream-prefix = shopapi-api
#   container name        = shopapi-api
#   task id               = ${TASK_ID}
LOG_STREAM="shopapi-api/shopapi-api/${TASK_ID}"

info "Buscando log stream: ${LOG_GROUP}/${LOG_STREAM} ..."

STREAM_EXISTS=$(aws logs describe-log-streams \
  --log-group-name "${LOG_GROUP}" \
  --log-stream-name-prefix "shopapi-api/shopapi-api/${TASK_ID}" \
  --region "${AWS_REGION}" \
  --query 'logStreams[0].logStreamName' \
  --output text 2>/dev/null || echo "")

if [[ -n "${STREAM_EXISTS}" && "${STREAM_EXISTS}" != "None" ]]; then
  ok "Log stream encontrado: ${STREAM_EXISTS}"
  echo ""
  info "Ultimos logs del contenedor:"
  echo "---"
  aws logs get-log-events \
    --log-group-name "${LOG_GROUP}" \
    --log-stream-name "${LOG_STREAM}" \
    --region "${AWS_REGION}" \
    --limit 20 \
    --query 'events[*].message' \
    --output text 2>/dev/null || warn "No se pudieron obtener los logs aun"
  echo "---"
else
  warn "El log stream aun no existe en CloudWatch."
  warn "Los logs pueden tardar hasta 30 segundos en aparecer."
  warn "Para verlos manualmente:"
  echo ""
  echo "  aws logs get-log-events \\"
  echo "    --log-group-name ${LOG_GROUP} \\"
  echo "    --log-stream-name ${LOG_STREAM} \\"
  echo "    --region ${AWS_REGION}"
fi

# =============================================================================
# RESUMEN FINAL
# =============================================================================
section "Resumen del Lab v1"

echo ""
ok "Todos los recursos creados exitosamente:"
echo ""
echo "  Cluster ECS    : ${CLUSTER_NAME}"
echo "  Task Family    : ${TASK_FAMILY}:${TASK_DEF_REVISION}"
echo "  Task ARN       : ${TASK_ARN}"
echo "  Execution Role : ${EXECUTION_ROLE_ARN}"
echo "  Log Group      : ${LOG_GROUP}"
echo ""
info "Para monitorizar el task:"
echo "  aws ecs describe-tasks --cluster ${CLUSTER_NAME} --tasks ${TASK_ARN} --region ${AWS_REGION}"
echo ""
info "Para ver los logs:"
echo "  aws logs get-log-events --log-group-name ${LOG_GROUP} --log-stream-name shopapi-api/shopapi-api/${TASK_ID} --region ${AWS_REGION}"
echo ""
info "Para limpiar todos los recursos:"
echo "  bash cli/99-cleanup.sh"
echo ""
