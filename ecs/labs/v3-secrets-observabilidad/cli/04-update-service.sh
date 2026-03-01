#!/usr/bin/env bash
# =============================================================================
# Lab v3 — Fase A5: Registrar nueva Task Definition y actualizar el Service
# ShopAPI — ECS Fargate
#
# Que hace este script:
#   1. Sustituye los placeholders ACCOUNT_ID en el JSON de la Task Definition
#   2. Registra la nueva revisión de la Task Definition (con secrets y task role)
#   3. Actualiza el Service ECS con la nueva revisión
#   4. Monitorea el deployment hasta que se completa
#   5. Verifica que los secrets se inyectaron correctamente
# =============================================================================
set -euo pipefail

# ─── Variables ───────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-eu-west-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_NAME="shopapi-cluster"
SERVICE_NAME="shopapi-service"
TASK_DEF_FAMILY="shopapi-api"
TASK_DEF_FILE="$(dirname "$0")/03-task-def-secrets.json"
DEPLOY_TIMEOUT=600  # 10 minutos máximo para el deployment

echo "========================================================"
echo "  Lab v3 — Actualizando Service con Secrets y Task Role"
echo "  Cuenta: ${ACCOUNT_ID}"
echo "  Region: ${AWS_REGION}"
echo "========================================================"
echo ""

# =============================================================================
# PREPARAR LA TASK DEFINITION
# =============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Paso 1: Preparando Task Definition"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ ! -f "${TASK_DEF_FILE}" ]]; then
  echo "[ERROR] No se encontró el archivo: ${TASK_DEF_FILE}"
  echo "        Ejecuta este script desde el directorio cli/ del lab v3."
  exit 1
fi

# Obtener el ARN del secret (necesitamos el ARN con sufijo para el valueFrom)
SECRET_ARN=$(aws secretsmanager describe-secret \
  --secret-id "shopapi/prod/db" \
  --region "${AWS_REGION}" \
  --query 'ARN' \
  --output text 2>/dev/null || echo "")

if [[ -z "${SECRET_ARN}" || "${SECRET_ARN}" == "None" ]]; then
  echo "[ERROR] No se encontró el secret 'shopapi/prod/db'."
  echo "        Ejecuta primero el script 01-secrets-iam.sh"
  exit 1
fi

# El ARN del secret incluye el sufijo (ej: shopapi/prod/db-AbCdEf)
# En el valueFrom, la referencia a una clave JSON tiene el formato:
# arn:aws:secretsmanager:REGION:ACCOUNT:secret:NOMBRE:CLAVE::
# El sufijo del ARN NO se incluye en el valueFrom cuando se usa con el nombre lógico
echo "[INFO] Secret ARN: ${SECRET_ARN}"

# Crear una copia temporal de la Task Definition con los ARNs reales
TEMP_TASK_DEF="/tmp/shopapi-task-def-v3-${ACCOUNT_ID}.json"
sed "s/ACCOUNT_ID/${ACCOUNT_ID}/g" "${TASK_DEF_FILE}" > "${TEMP_TASK_DEF}"

echo "[INFO] Task Definition preparada en: ${TEMP_TASK_DEF}"
echo ""
echo "[INFO] Verificando roles IAM reemplazados:"
grep -E "taskRoleArn|executionRoleArn" "${TEMP_TASK_DEF}"

echo ""
echo "[INFO] Verificando secrets configurados:"
python3 -c "
import json, sys
with open('${TEMP_TASK_DEF}') as f:
    td = json.load(f)
for s in td['containerDefinitions'][0].get('secrets', []):
    print(f\"  {s['name']} → {s['valueFrom']}\")
"

# =============================================================================
# REGISTRAR LA TASK DEFINITION
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Paso 2: Registrando nueva revisión de la Task Definition"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

NEW_TASK_DEF_ARN=$(aws ecs register-task-definition \
  --cli-input-json "file://${TEMP_TASK_DEF}" \
  --region "${AWS_REGION}" \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

NEW_REVISION=$(echo "${NEW_TASK_DEF_ARN}" | awk -F: '{print $NF}')

echo "[OK] Nueva Task Definition registrada:"
echo "     ARN: ${NEW_TASK_DEF_ARN}"
echo "     Familia: ${TASK_DEF_FAMILY}"
echo "     Revisión: ${NEW_REVISION}"

# Verificar la Task Definition registrada
echo ""
echo "[INFO] Detalles de la Task Definition registrada:"
aws ecs describe-task-definition \
  --task-definition "${NEW_TASK_DEF_ARN}" \
  --region "${AWS_REGION}" \
  --query 'taskDefinition.{
    revision:revision,
    taskRoleArn:taskRoleArn,
    executionRoleArn:executionRoleArn,
    secrets:containerDefinitions[0].secrets,
    healthCheck:containerDefinitions[0].healthCheck
  }' \
  --output json

# =============================================================================
# ACTUALIZAR EL SERVICE
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Paso 3: Actualizando Service ECS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Obtener la Task Definition actual antes de actualizar
CURRENT_TASK_DEF=$(aws ecs describe-services \
  --cluster "${CLUSTER_NAME}" \
  --services "${SERVICE_NAME}" \
  --region "${AWS_REGION}" \
  --query 'services[0].taskDefinition' \
  --output text)

echo "[INFO] Task Definition actual: ${CURRENT_TASK_DEF}"
echo "[INFO] Nueva Task Definition:  ${NEW_TASK_DEF_ARN}"
echo ""

aws ecs update-service \
  --cluster "${CLUSTER_NAME}" \
  --service "${SERVICE_NAME}" \
  --task-definition "${NEW_TASK_DEF_ARN}" \
  --region "${AWS_REGION}" \
  --query 'service.{
    nombre:serviceName,
    estado:status,
    desiredCount:desiredCount,
    runningCount:runningCount,
    deployments:deployments[*].{id:id,estado:status,deseadas:desiredCount,corriendo:runningCount,taskDef:taskDefinition}
  }' \
  --output json

echo ""
echo "[OK] Service actualizado. Iniciando deployment rolling update..."

# =============================================================================
# MONITOREAR EL DEPLOYMENT
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Paso 4: Monitoreando el deployment"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  El rolling update reemplazará las tareas de una en una."
echo "  Espera a que 'deployments' tenga solo 1 entrada con status PRIMARY."
echo ""

ELAPSED=0
POLL_INTERVAL=15

while true; do
  DEPLOYMENTS=$(aws ecs describe-services \
    --cluster "${CLUSTER_NAME}" \
    --services "${SERVICE_NAME}" \
    --region "${AWS_REGION}" \
    --query 'services[0].deployments' \
    --output json)

  DEPLOYMENT_COUNT=$(echo "${DEPLOYMENTS}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))")
  PRIMARY_STATUS=$(echo "${DEPLOYMENTS}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
primary = next((x for x in d if x['status'] == 'PRIMARY'), None)
if primary:
    print(f\"PRIMARY: {primary.get('runningCount',0)}/{primary.get('desiredCount',0)} tareas\")
else:
    print('PRIMARY no encontrado')
")
  RUNNING=$(aws ecs describe-services \
    --cluster "${CLUSTER_NAME}" \
    --services "${SERVICE_NAME}" \
    --region "${AWS_REGION}" \
    --query 'services[0].runningCount' \
    --output text)
  DESIRED=$(aws ecs describe-services \
    --cluster "${CLUSTER_NAME}" \
    --services "${SERVICE_NAME}" \
    --region "${AWS_REGION}" \
    --query 'services[0].desiredCount' \
    --output text)

  TIMESTAMP=$(date '+%H:%M:%S')
  echo "[${TIMESTAMP}] Deployments: ${DEPLOYMENT_COUNT} | ${PRIMARY_STATUS} | Running: ${RUNNING}/${DESIRED}"

  # El deployment se completa cuando solo queda 1 deployment (PRIMARY)
  # y el running count == desired count
  if [[ "${DEPLOYMENT_COUNT}" == "1" && "${RUNNING}" == "${DESIRED}" ]]; then
    echo ""
    echo "[OK] Deployment completado con exito."
    break
  fi

  if [[ ${ELAPSED} -ge ${DEPLOY_TIMEOUT} ]]; then
    echo ""
    echo "[WARN] Timeout alcanzado (${DEPLOY_TIMEOUT}s). El deployment puede seguir en progreso."
    echo "       Comprueba el estado manualmente:"
    echo "       aws ecs describe-services --cluster ${CLUSTER_NAME} --services ${SERVICE_NAME}"
    break
  fi

  sleep ${POLL_INTERVAL}
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

# =============================================================================
# VERIFICACIÓN DE SECRETS INYECTADOS
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Paso 5: Verificando que los secrets se inyectaron"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Obtener una tarea en ejecución
TASK_ARN=$(aws ecs list-tasks \
  --cluster "${CLUSTER_NAME}" \
  --service-name "${SERVICE_NAME}" \
  --desired-status RUNNING \
  --region "${AWS_REGION}" \
  --query 'taskArns[0]' \
  --output text)

if [[ -z "${TASK_ARN}" || "${TASK_ARN}" == "None" ]]; then
  echo "[WARN] No hay tareas en estado RUNNING para verificar."
  echo "       Espera unos minutos e intenta manualmente:"
  echo "       aws ecs list-tasks --cluster ${CLUSTER_NAME} --service-name ${SERVICE_NAME}"
else
  echo "[INFO] Tarea seleccionada: ${TASK_ARN}"
  echo ""

  # Ver detalles de la tarea
  echo "[INFO] Estado de la tarea y health check:"
  aws ecs describe-tasks \
    --cluster "${CLUSTER_NAME}" \
    --tasks "${TASK_ARN}" \
    --region "${AWS_REGION}" \
    --query 'tasks[0].{
      taskArn:taskArn,
      lastStatus:lastStatus,
      desiredStatus:desiredStatus,
      taskDefinitionArn:taskDefinitionArn,
      container:{
        nombre:containers[0].name,
        estado:containers[0].lastStatus,
        health:containers[0].healthStatus,
        imagen:containers[0].image
      }
    }' \
    --output json

  echo ""
  echo "[INFO] IMPORTANTE: Los valores de los secrets NO aparecen en describe-tasks."
  echo "       Solo se muestran los NOMBRES de las variables de entorno."
  echo "       Los valores están cifrados y solo son accesibles dentro del contenedor."
  echo ""
  echo "[INFO] Para verificar DENTRO del contenedor (solo en desarrollo):"
  echo "       # Si tuvieras acceso a ECS Exec (requiere SSM Agent en Fargate):"
  echo "       aws ecs execute-command \\"
  echo "         --cluster ${CLUSTER_NAME} \\"
  echo "         --task ${TASK_ARN} \\"
  echo "         --container shopapi-api \\"
  echo "         --command 'printenv | grep DB_' \\"
  echo "         --interactive"
fi

# =============================================================================
# VERIFICAR HEALTH DEL ALB
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Paso 6: Verificando health del Target Group en el ALB"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "shopapi-alb" \
  --region "${AWS_REGION}" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text 2>/dev/null || echo "")

if [[ -n "${ALB_ARN}" && "${ALB_ARN}" != "None" ]]; then
  TG_ARN=$(aws elbv2 describe-target-groups \
    --load-balancer-arn "${ALB_ARN}" \
    --region "${AWS_REGION}" \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text 2>/dev/null || echo "")

  if [[ -n "${TG_ARN}" && "${TG_ARN}" != "None" ]]; then
    echo "[INFO] Estado de los targets en el Target Group:"
    aws elbv2 describe-target-health \
      --target-group-arn "${TG_ARN}" \
      --region "${AWS_REGION}" \
      --query 'TargetHealthDescriptions[*].{
        IP:Target.Id,
        Puerto:Target.Port,
        Estado:TargetHealth.State,
        Descripcion:TargetHealth.Description
      }' \
      --output table
  fi
fi

# =============================================================================
# RESUMEN FINAL
# =============================================================================
echo ""
echo "========================================================"
echo "  RESUMEN — Deployment v3 completado"
echo "========================================================"
echo ""
echo "  Task Definition: ${NEW_TASK_DEF_ARN}"
echo "  Cluster: ${CLUSTER_NAME}"
echo "  Service: ${SERVICE_NAME}"
echo ""
echo "  Cambios aplicados:"
echo "    - taskRoleArn: arn:aws:iam::${ACCOUNT_ID}:role/shopapi-task-role"
echo "    - Secrets: DB_HOST, DB_PORT, DB_USERNAME, DB_PASSWORD desde Secrets Manager"
echo "    - Health check container con startPeriod: 30s"
echo ""
echo "  Para verificar el endpoint:"
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names "shopapi-alb" \
  --region "${AWS_REGION}" \
  --query 'LoadBalancers[0].DNSName' \
  --output text 2>/dev/null || echo "shopapi-alb.amazonaws.com")
echo "    curl http://${ALB_DNS}/health"
echo ""
echo "  Para ver logs en CloudWatch:"
echo "    aws logs tail /ecs/shopapi-api --follow --region ${AWS_REGION}"
echo ""
echo "  Lab v3 completado. Consulta el README para la sección de validación."
echo "========================================================"

# Limpieza del archivo temporal
rm -f "${TEMP_TASK_DEF}"
