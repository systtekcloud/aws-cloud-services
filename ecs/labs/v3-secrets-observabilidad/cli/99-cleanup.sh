#!/usr/bin/env bash
# =============================================================================
# Lab v3 — Limpieza de recursos
# ShopAPI — ECS Fargate
#
# ATENCION: Este script elimina recursos creados en el Lab v3.
# Los recursos de v1/v2 (cluster, service, ALB, VPC) NO se eliminan aqui.
# Para limpiar v1/v2, usar el script de limpieza correspondiente de esos labs.
#
# Recursos que elimina este script:
#   - CloudWatch Alarms (3 alarmas)
#   - CloudWatch Dashboard shopapi-overview
#   - SNS Topic shopapi-alertas y suscripciones
#   - Container Insights (deshabilitado, no eliminado)
#   - IAM Role shopapi-task-role + política inline DynamoDB
#   - IAM Policy inline shopapi-secrets-access del Execution Role
#   - Secret shopapi/prod/db en Secrets Manager
#   - Task Definition v3 (se desregistra, las anteriores quedan activas)
# =============================================================================
set -euo pipefail

# ─── Variables ───────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-eu-west-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_NAME="shopapi-cluster"
SERVICE_NAME="shopapi-service"
SECRET_NAME="shopapi/prod/db"
TASK_ROLE_NAME="shopapi-task-role"
EXECUTION_ROLE_NAME="shopapi-execution-role"
SNS_TOPIC_NAME="shopapi-alertas"

echo "========================================================"
echo "  Lab v3 — LIMPIEZA DE RECURSOS"
echo "  Cuenta: ${ACCOUNT_ID}"
echo "  Region: ${AWS_REGION}"
echo "========================================================"
echo ""
echo "  ATENCION: Se eliminarán los recursos del Lab v3."
echo "  Los recursos de v1/v2 (cluster, ALB, VPC) NO se tocan."
echo ""
read -p "  ¿Confirmas la limpieza? (escribe 'si' para continuar): " CONFIRMACION

if [[ "${CONFIRMACION}" != "si" ]]; then
  echo "Limpieza cancelada."
  exit 0
fi

echo ""
echo "Iniciando limpieza..."

# Función auxiliar para continuar si un recurso no existe
resource_not_found() {
  echo "[INFO] Recurso no encontrado o ya eliminado: $1"
}

# =============================================================================
# 1. ELIMINAR CLOUDWATCH ALARMS
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Paso 1: Eliminando CloudWatch Alarms"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ALARMS_TO_DELETE=(
  "shopapi-alb-5xx-rate"
  "shopapi-alb-latencia-p99"
  "shopapi-ecs-tareas-unhealthy"
)

for ALARM in "${ALARMS_TO_DELETE[@]}"; do
  if aws cloudwatch describe-alarms \
      --alarm-names "${ALARM}" \
      --region "${AWS_REGION}" \
      --query 'MetricAlarms[0].AlarmName' \
      --output text 2>/dev/null | grep -q "${ALARM}"; then
    aws cloudwatch delete-alarms \
      --alarm-names "${ALARM}" \
      --region "${AWS_REGION}"
    echo "[OK] Alarma eliminada: ${ALARM}"
  else
    resource_not_found "Alarma: ${ALARM}"
  fi
done

# =============================================================================
# 2. ELIMINAR CLOUDWATCH DASHBOARD
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Paso 2: Eliminando CloudWatch Dashboard"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if aws cloudwatch get-dashboard \
    --dashboard-name "shopapi-overview" \
    --region "${AWS_REGION}" \
    --output text > /dev/null 2>&1; then
  aws cloudwatch delete-dashboards \
    --dashboard-names "shopapi-overview" \
    --region "${AWS_REGION}"
  echo "[OK] Dashboard 'shopapi-overview' eliminado."
else
  resource_not_found "Dashboard: shopapi-overview"
fi

# =============================================================================
# 3. ELIMINAR SNS TOPIC Y SUSCRIPCIONES
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Paso 3: Eliminando SNS Topic y suscripciones"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

SNS_TOPIC_ARN="arn:aws:sns:${AWS_REGION}:${ACCOUNT_ID}:${SNS_TOPIC_NAME}"

# Eliminar suscripciones primero
SUBSCRIPTIONS=$(aws sns list-subscriptions-by-topic \
  --topic-arn "${SNS_TOPIC_ARN}" \
  --region "${AWS_REGION}" \
  --query 'Subscriptions[*].SubscriptionArn' \
  --output text 2>/dev/null || echo "")

if [[ -n "${SUBSCRIPTIONS}" ]]; then
  for SUB_ARN in ${SUBSCRIPTIONS}; do
    # Las suscripciones pendientes de confirmación tienen ARN "PendingConfirmation"
    if [[ "${SUB_ARN}" != "PendingConfirmation" ]]; then
      aws sns unsubscribe \
        --subscription-arn "${SUB_ARN}" \
        --region "${AWS_REGION}" 2>/dev/null || true
      echo "[OK] Suscripción eliminada: ${SUB_ARN}"
    fi
  done
fi

# Eliminar el topic
if aws sns get-topic-attributes \
    --topic-arn "${SNS_TOPIC_ARN}" \
    --region "${AWS_REGION}" \
    --output text > /dev/null 2>&1; then
  aws sns delete-topic \
    --topic-arn "${SNS_TOPIC_ARN}" \
    --region "${AWS_REGION}"
  echo "[OK] SNS Topic eliminado: ${SNS_TOPIC_ARN}"
else
  resource_not_found "SNS Topic: ${SNS_TOPIC_NAME}"
fi

# =============================================================================
# 4. DESHABILITAR CONTAINER INSIGHTS
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Paso 4: Deshabilitando Container Insights"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

CONTAINER_INSIGHTS_STATUS=$(aws ecs describe-clusters \
  --clusters "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --query 'clusters[0].settings[?name==`containerInsights`].value' \
  --output text 2>/dev/null || echo "disabled")

if [[ "${CONTAINER_INSIGHTS_STATUS}" == "enabled" ]]; then
  aws ecs update-cluster-settings \
    --cluster "${CLUSTER_NAME}" \
    --settings name=containerInsights,value=disabled \
    --region "${AWS_REGION}" \
    --output text > /dev/null
  echo "[OK] Container Insights deshabilitado en el cluster '${CLUSTER_NAME}'."
else
  echo "[INFO] Container Insights ya estaba deshabilitado."
fi

# =============================================================================
# 5. ELIMINAR TASK ROLE Y SUS POLÍTICAS
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Paso 5: Eliminando Task Role (${TASK_ROLE_NAME})"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if aws iam get-role --role-name "${TASK_ROLE_NAME}" > /dev/null 2>&1; then
  # Eliminar políticas inline primero (no se pueden eliminar el rol con políticas adjuntas)
  INLINE_POLICIES=$(aws iam list-role-policies \
    --role-name "${TASK_ROLE_NAME}" \
    --query 'PolicyNames' \
    --output text 2>/dev/null || echo "")

  for POLICY_NAME in ${INLINE_POLICIES}; do
    aws iam delete-role-policy \
      --role-name "${TASK_ROLE_NAME}" \
      --policy-name "${POLICY_NAME}"
    echo "[OK] Política inline eliminada: ${POLICY_NAME}"
  done

  # Desadjuntar políticas gestionadas
  ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
    --role-name "${TASK_ROLE_NAME}" \
    --query 'AttachedPolicies[*].PolicyArn' \
    --output text 2>/dev/null || echo "")

  for POLICY_ARN in ${ATTACHED_POLICIES}; do
    aws iam detach-role-policy \
      --role-name "${TASK_ROLE_NAME}" \
      --policy-arn "${POLICY_ARN}"
    echo "[OK] Política gestionada desadjuntada: ${POLICY_ARN}"
  done

  # Eliminar el rol
  aws iam delete-role \
    --role-name "${TASK_ROLE_NAME}"
  echo "[OK] Task Role eliminado: ${TASK_ROLE_NAME}"
else
  resource_not_found "IAM Role: ${TASK_ROLE_NAME}"
fi

# =============================================================================
# 6. ELIMINAR POLÍTICA INLINE DEL EXECUTION ROLE
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Paso 6: Eliminando política shopapi-secrets-access del Execution Role"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if aws iam get-role-policy \
    --role-name "${EXECUTION_ROLE_NAME}" \
    --policy-name "shopapi-secrets-access" \
    > /dev/null 2>&1; then
  aws iam delete-role-policy \
    --role-name "${EXECUTION_ROLE_NAME}" \
    --policy-name "shopapi-secrets-access"
  echo "[OK] Política 'shopapi-secrets-access' eliminada del Execution Role."
else
  resource_not_found "Política shopapi-secrets-access en ${EXECUTION_ROLE_NAME}"
fi

# =============================================================================
# 7. ELIMINAR SECRET DE SECRETS MANAGER
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Paso 7: Eliminando Secret en Secrets Manager"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if aws secretsmanager describe-secret \
    --secret-id "${SECRET_NAME}" \
    --region "${AWS_REGION}" \
    --output text > /dev/null 2>&1; then

  echo ""
  echo "  Opciones de eliminación del secret:"
  echo "  [1] Con periodo de recuperación de 7 días (recomendado para producción)"
  echo "  [2] Eliminación inmediata sin recuperación (para laboratorio)"
  echo ""
  read -p "  ¿Qué opción prefieres? (1/2): " DELETE_OPTION

  if [[ "${DELETE_OPTION}" == "2" ]]; then
    aws secretsmanager delete-secret \
      --secret-id "${SECRET_NAME}" \
      --force-delete-without-recovery \
      --region "${AWS_REGION}" \
      --query '{Nombre:Name,Estado:DeletionDate}' \
      --output json
    echo "[OK] Secret '${SECRET_NAME}' eliminado inmediatamente."
  else
    aws secretsmanager delete-secret \
      --secret-id "${SECRET_NAME}" \
      --recovery-window-in-days 7 \
      --region "${AWS_REGION}" \
      --query '{Nombre:Name,FechaEliminacion:DeletionDate}' \
      --output json
    echo "[OK] Secret '${SECRET_NAME}' marcado para eliminación en 7 días."
    echo "     Para cancelar: aws secretsmanager restore-secret --secret-id ${SECRET_NAME}"
  fi
else
  resource_not_found "Secret: ${SECRET_NAME}"
fi

# =============================================================================
# 8. DESREGISTRAR TASK DEFINITIONS v3
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Paso 8: Desregistrando Task Definitions con secrets (v3)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Nota: Las Task Definitions desregistradas no se eliminan;"
echo "  quedan en estado INACTIVE y se pueden ver pero no usar."
echo "  El Service sigue usando la última versión activa de v2."
echo ""

# Obtener las revisiones activas de shopapi-api que tengan taskRoleArn (las de v3)
ACTIVE_REVISIONS=$(aws ecs list-task-definitions \
  --family-prefix "shopapi-api" \
  --status ACTIVE \
  --region "${AWS_REGION}" \
  --query 'taskDefinitionArns' \
  --output json 2>/dev/null || echo "[]")

echo "[INFO] Task Definitions activas de la familia shopapi-api:"
echo "${ACTIVE_REVISIONS}" | python3 -c "
import json, sys
arns = json.load(sys.stdin)
for arn in arns:
    rev = arn.split(':')[-1]
    print(f'  Revision {rev}: {arn}')
"

echo ""
echo "  Las Task Definitions NO se desregistran automáticamente."
echo "  El service de ECS quedará en la última versión que tenía antes de v3,"
echo "  o puedes revertir manualmente con:"
echo ""
echo "  aws ecs update-service \\"
echo "    --cluster ${CLUSTER_NAME} \\"
echo "    --service ${SERVICE_NAME} \\"
echo "    --task-definition shopapi-api:NUMERO_REVISION_V2"

# =============================================================================
# RESUMEN FINAL
# =============================================================================
echo ""
echo "========================================================"
echo "  LIMPIEZA COMPLETADA"
echo "========================================================"
echo ""
echo "  Eliminados:"
echo "    - CloudWatch Alarms: shopapi-alb-5xx-rate, shopapi-alb-latencia-p99, shopapi-ecs-tareas-unhealthy"
echo "    - CloudWatch Dashboard: shopapi-overview"
echo "    - SNS Topic: ${SNS_TOPIC_NAME}"
echo "    - Container Insights: deshabilitado"
echo "    - IAM Role: ${TASK_ROLE_NAME} (con políticas inline)"
echo "    - IAM Policy inline: shopapi-secrets-access (del Execution Role)"
echo "    - Secret: ${SECRET_NAME}"
echo ""
echo "  Recursos de v1/v2 intactos:"
echo "    - Cluster ECS: ${CLUSTER_NAME}"
echo "    - Service ECS: ${SERVICE_NAME}"
echo "    - Execution Role: ${EXECUTION_ROLE_NAME} (sin la política v3)"
echo "    - ALB, VPC, subnets, security groups"
echo ""
echo "  Para limpiar también v1/v2, usa el script 99-cleanup.sh"
echo "  del Lab v2."
echo "========================================================"
