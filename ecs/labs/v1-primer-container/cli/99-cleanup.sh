#!/usr/bin/env bash
# =============================================================================
# Lab v1 — ShopAPI en ECS Fargate
# Script 99: Limpieza — Eliminar todos los recursos del lab
#
# Uso:
#   bash cli/99-cleanup.sh
#
# ATENCION: Este script elimina TODOS los recursos creados en el lab.
# Asegurate de que ya no necesitas ninguno de estos recursos antes de ejecutarlo.
#
# Orden de eliminacion (importante para evitar errores de dependencias):
#   1. Parar tasks en ejecucion
#   2. Deregistrar Task Definitions
#   3. Eliminar cluster ECS
#   4. Eliminar imagenes y repositorio ECR
#   5. Eliminar log group de CloudWatch
#   6. Desadjuntar policies y eliminar IAM role
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
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${YELLOW}========================================${NC}"; \
            echo -e "${YELLOW}  $*${NC}"; \
            echo -e "${YELLOW}========================================${NC}\n"; }

# Funcion auxiliar: ejecutar comando y no fallar si el recurso no existe
safe_run() {
  local description="$1"
  shift
  if "$@" 2>/dev/null; then
    ok "${description}"
  else
    warn "${description} — recurso no encontrado o ya eliminado, continuando..."
  fi
}

# =============================================================================
# CONFIRMACION DE SEGURIDAD
# =============================================================================
section "Script de Limpieza del Lab v1"

echo -e "${RED}ATENCION: Este script eliminara los siguientes recursos de AWS:${NC}"
echo ""
echo "  - ECS Tasks en ejecucion (cluster: shopapi-cluster)"
echo "  - ECS Task Definitions (familia: shopapi-api)"
echo "  - ECS Cluster: shopapi-cluster"
echo "  - ECR Repository: shopapi/api (con todas sus imagenes)"
echo "  - CloudWatch Log Group: /ecs/shopapi"
echo "  - IAM Role: shopapi-execution-role"
echo ""

read -r -p "¿Estas seguro de que quieres eliminar todos estos recursos? [s/N] " CONFIRM
if [[ "${CONFIRM}" != "s" && "${CONFIRM}" != "S" ]]; then
  echo "Operacion cancelada por el usuario."
  exit 0
fi

echo ""

# =============================================================================
# CONFIGURACION DE VARIABLES
# =============================================================================
section "Configurando variables"

export AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
export AWS_REGION="${AWS_REGION:-eu-west-1}"

CLUSTER_NAME="shopapi-cluster"
TASK_FAMILY="shopapi-api"
ECR_REPO_NAME="shopapi/api"
LOG_GROUP="/ecs/shopapi"
EXECUTION_ROLE_NAME="shopapi-execution-role"

info "Variables de limpieza:"
echo "  AWS Account ID : ${AWS_ACCOUNT_ID}"
echo "  AWS Region     : ${AWS_REGION}"
echo "  Cluster        : ${CLUSTER_NAME}"
echo "  Task Family    : ${TASK_FAMILY}"
echo "  ECR Repo       : ${ECR_REPO_NAME}"
echo "  Log Group      : ${LOG_GROUP}"
echo "  IAM Role       : ${EXECUTION_ROLE_NAME}"
echo ""

# =============================================================================
# PASO 1: Parar todos los tasks en ejecucion
# =============================================================================
section "Paso 1/6 — Parando tasks en ejecucion"

# Verificar si el cluster existe antes de intentar listar tasks
CLUSTER_EXISTS=$(aws ecs describe-clusters \
  --clusters "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --query "clusters[?status=='ACTIVE'].clusterName" \
  --output text 2>/dev/null || echo "")

if [[ -n "${CLUSTER_EXISTS}" ]]; then
  # Obtener ARNs de todos los tasks en el cluster (cualquier estado)
  RUNNING_TASKS=$(aws ecs list-tasks \
    --cluster "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --query 'taskArns[]' \
    --output text 2>/dev/null || echo "")

  if [[ -n "${RUNNING_TASKS}" ]]; then
    info "Tasks encontradas para parar:"
    for TASK_ARN in ${RUNNING_TASKS}; do
      echo "  Parando: ${TASK_ARN}"
      aws ecs stop-task \
        --cluster "${CLUSTER_NAME}" \
        --task "${TASK_ARN}" \
        --reason "Limpieza del lab v1" \
        --region "${AWS_REGION}" \
        --query 'task.{Status:lastStatus, StopCode:stopCode}' \
        --output table 2>/dev/null || warn "No se pudo parar: ${TASK_ARN}"
    done

    # Esperar a que todas las tasks se detengan
    info "Esperando a que los tasks se detengan completamente (30 segundos) ..."
    sleep 30
    ok "Todos los tasks detenidos"
  else
    ok "No hay tasks en ejecucion en el cluster"
  fi
else
  warn "El cluster '${CLUSTER_NAME}' no existe o no esta ACTIVE"
  ok "No hay tasks que parar"
fi

# =============================================================================
# PASO 2: Deregistrar Task Definitions
# =============================================================================
section "Paso 2/6 — Deregistrando Task Definitions"

# Listar todas las revisiones de la familia shopapi-api
TASK_DEF_ARNS=$(aws ecs list-task-definitions \
  --family-prefix "${TASK_FAMILY}" \
  --region "${AWS_REGION}" \
  --query 'taskDefinitionArns[]' \
  --output text 2>/dev/null || echo "")

if [[ -n "${TASK_DEF_ARNS}" ]]; then
  REVISION_COUNT=0
  for TD_ARN in ${TASK_DEF_ARNS}; do
    echo "  Deregistrando: ${TD_ARN}"
    aws ecs deregister-task-definition \
      --task-definition "${TD_ARN}" \
      --region "${AWS_REGION}" \
      --query 'taskDefinition.{Familia:family, Revision:revision, Estado:status}' \
      --output table 2>/dev/null || warn "No se pudo deregistrar: ${TD_ARN}"
    REVISION_COUNT=$((REVISION_COUNT + 1))
  done
  ok "${REVISION_COUNT} revision(es) de '${TASK_FAMILY}' deregistradas"
else
  warn "No se encontraron Task Definitions para la familia '${TASK_FAMILY}'"
fi

# =============================================================================
# PASO 3: Eliminar cluster ECS
# =============================================================================
section "Paso 3/6 — Eliminando cluster ECS"

# Nota: el cluster solo se puede eliminar si no tiene tasks ni servicios activos
# (ya los paramos en el paso 1)
if [[ -n "${CLUSTER_EXISTS}" ]]; then
  info "Eliminando cluster: ${CLUSTER_NAME} ..."
  aws ecs delete-cluster \
    --cluster "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --query 'cluster.{Nombre:clusterName, Estado:status}' \
    --output table

  ok "Cluster '${CLUSTER_NAME}' eliminado"
else
  warn "El cluster '${CLUSTER_NAME}' no existe — nada que eliminar"
fi

# =============================================================================
# PASO 4: Eliminar imagenes y repositorio ECR
# =============================================================================
section "Paso 4/6 — Eliminando repositorio ECR"

REPO_EXISTS=$(aws ecr describe-repositories \
  --repository-names "${ECR_REPO_NAME}" \
  --region "${AWS_REGION}" \
  --query 'repositories[0].repositoryName' \
  --output text 2>/dev/null || echo "NO_EXISTE")

if [[ "${REPO_EXISTS}" != "NO_EXISTE" ]]; then
  # Listar todas las imagenes en el repositorio
  IMAGE_IDS=$(aws ecr list-images \
    --repository-name "${ECR_REPO_NAME}" \
    --region "${AWS_REGION}" \
    --query 'imageIds[*]' \
    --output json 2>/dev/null || echo "[]")

  IMAGE_COUNT=$(echo "${IMAGE_IDS}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

  if [[ "${IMAGE_COUNT}" -gt "0" ]]; then
    info "Eliminando ${IMAGE_COUNT} imagen(es) del repositorio ..."
    aws ecr batch-delete-image \
      --repository-name "${ECR_REPO_NAME}" \
      --region "${AWS_REGION}" \
      --image-ids "${IMAGE_IDS}" \
      --query '{Eliminadas:imageIds[*].imageTag, Fallos:failures[*].failureReason}' \
      --output table 2>/dev/null || warn "Algunas imagenes no se pudieron eliminar"
    ok "Imagenes eliminadas del repositorio"
  else
    info "El repositorio esta vacio — no hay imagenes que eliminar"
  fi

  # Eliminar el repositorio (--force en caso de que queden imagenes sin tag)
  info "Eliminando repositorio ECR: ${ECR_REPO_NAME} ..."
  aws ecr delete-repository \
    --repository-name "${ECR_REPO_NAME}" \
    --region "${AWS_REGION}" \
    --force \
    --query 'repository.{Nombre:repositoryName, ARN:repositoryArn}' \
    --output table

  ok "Repositorio ECR '${ECR_REPO_NAME}' eliminado"
else
  warn "El repositorio ECR '${ECR_REPO_NAME}' no existe — nada que eliminar"
fi

# =============================================================================
# PASO 5: Eliminar CloudWatch Log Group
# =============================================================================
section "Paso 5/6 — Eliminando CloudWatch Log Group"

# ATENCION: Esto elimina TODOS los logs del contenedor de forma permanente
# Asegurate de haber revisado los logs antes de ejecutar este paso

LOG_GROUP_EXISTS=$(aws logs describe-log-groups \
  --log-group-name-prefix "${LOG_GROUP}" \
  --region "${AWS_REGION}" \
  --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName" \
  --output text 2>/dev/null || echo "")

if [[ -n "${LOG_GROUP_EXISTS}" ]]; then
  # Contar cuantos log streams hay antes de eliminar
  STREAM_COUNT=$(aws logs describe-log-streams \
    --log-group-name "${LOG_GROUP}" \
    --region "${AWS_REGION}" \
    --query 'length(logStreams)' \
    --output text 2>/dev/null || echo "desconocido")

  warn "Se eliminaran ${STREAM_COUNT} log stream(s) del grupo: ${LOG_GROUP}"
  info "Eliminando log group: ${LOG_GROUP} ..."

  aws logs delete-log-group \
    --log-group-name "${LOG_GROUP}" \
    --region "${AWS_REGION}"

  ok "Log group '${LOG_GROUP}' eliminado (${STREAM_COUNT} streams borrados)"
else
  warn "El log group '${LOG_GROUP}' no existe — nada que eliminar"
fi

# =============================================================================
# PASO 6: Eliminar IAM Role y policies adjuntas
# =============================================================================
section "Paso 6/6 — Eliminando IAM Role"

# Para eliminar un IAM Role, primero hay que desadjuntar todas sus policies
# (tanto las gestionadas como las inline)

ROLE_EXISTS=$(aws iam get-role \
  --role-name "${EXECUTION_ROLE_NAME}" \
  --query 'Role.RoleName' \
  --output text 2>/dev/null || echo "NO_EXISTE")

if [[ "${ROLE_EXISTS}" != "NO_EXISTE" ]]; then
  # 6.1 Desadjuntar policies gestionadas
  ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
    --role-name "${EXECUTION_ROLE_NAME}" \
    --query 'AttachedPolicies[*].PolicyArn' \
    --output text 2>/dev/null || echo "")

  if [[ -n "${ATTACHED_POLICIES}" ]]; then
    for POLICY_ARN in ${ATTACHED_POLICIES}; do
      echo "  Desadjuntando policy: ${POLICY_ARN}"
      aws iam detach-role-policy \
        --role-name "${EXECUTION_ROLE_NAME}" \
        --policy-arn "${POLICY_ARN}"
      ok "Policy desadjuntada: ${POLICY_ARN}"
    done
  else
    info "No hay policies gestionadas adjuntas al rol"
  fi

  # 6.2 Eliminar policies inline (si las hubiera)
  INLINE_POLICIES=$(aws iam list-role-policies \
    --role-name "${EXECUTION_ROLE_NAME}" \
    --query 'PolicyNames[]' \
    --output text 2>/dev/null || echo "")

  if [[ -n "${INLINE_POLICIES}" ]]; then
    for POLICY_NAME in ${INLINE_POLICIES}; do
      echo "  Eliminando policy inline: ${POLICY_NAME}"
      aws iam delete-role-policy \
        --role-name "${EXECUTION_ROLE_NAME}" \
        --policy-name "${POLICY_NAME}"
      ok "Policy inline eliminada: ${POLICY_NAME}"
    done
  fi

  # 6.3 Eliminar el rol
  info "Eliminando IAM Role: ${EXECUTION_ROLE_NAME} ..."
  aws iam delete-role \
    --role-name "${EXECUTION_ROLE_NAME}"

  ok "IAM Role '${EXECUTION_ROLE_NAME}' eliminado"
else
  warn "El IAM Role '${EXECUTION_ROLE_NAME}' no existe — nada que eliminar"
fi

# =============================================================================
# RESUMEN DE LIMPIEZA
# =============================================================================
section "Limpieza completada"

echo ""
ok "Todos los recursos del Lab v1 han sido eliminados:"
echo ""
echo "  [OK] ECS Tasks          : paradas y terminadas"
echo "  [OK] Task Definitions   : familia '${TASK_FAMILY}' deregistrada"
echo "  [OK] ECS Cluster        : '${CLUSTER_NAME}' eliminado"
echo "  [OK] ECR Repository     : '${ECR_REPO_NAME}' eliminado con sus imagenes"
echo "  [OK] CloudWatch Logs    : '${LOG_GROUP}' eliminado"
echo "  [OK] IAM Role           : '${EXECUTION_ROLE_NAME}' eliminado"
echo ""
info "La cuenta de AWS esta limpia de recursos del Lab v1."
info "No se generaran mas costes por estos recursos."
echo ""
