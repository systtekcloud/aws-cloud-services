#!/usr/bin/env bash
# =============================================================================
# Lab v4 — Fase A3: SQS Orders Queue + ECS Workers con Capacity Providers
# =============================================================================
# Descripcion: Crea la infraestructura completa de workers:
#                1. SQS DLQ + Queue principal con redrive policy
#                2. ECS Service shopapi-worker con FARGATE + FARGATE_SPOT
#                3. Auto Scaling de workers basado en SQS backlog por task
#                4. Script de prueba: envio de mensajes y observacion del escalado
#
# Prereqs:     Fase A2 completada. task-def-worker.json en el mismo directorio.
# Uso:         bash 03-sqs-workers.sh
#              bash 03-sqs-workers.sh --enviar-mensajes   (solo envia mensajes)
#              bash 03-sqs-workers.sh --publicar-metrica  (solo publica metrica CW)
#              bash 03-sqs-workers.sh --simular-spot      (simula interrupcion Spot)
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Colores para output
# -----------------------------------------------------------------------------
VERDE='\033[0;32m'
AMARILLO='\033[1;33m'
AZUL='\033[0;34m'
ROJO='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${VERDE}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${AMARILLO}[WARN]${NC}  $1"; }
log_paso()  { echo -e "${AZUL}[PASO]${NC}  $1"; }
log_spot()  { echo -e "${CYAN}[SPOT]${NC}  $1"; }
log_error() { echo -e "${ROJO}[ERROR]${NC} $1"; exit 1; }

# -----------------------------------------------------------------------------
# Variables de configuracion
# -----------------------------------------------------------------------------
REGION="${AWS_DEFAULT_REGION:-eu-west-1}"
CLUSTER="${CLUSTER:-shopapi-cluster}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")

# SQS
QUEUE_NAME="shopapi-orders"
DLQ_NAME="shopapi-orders-dlq"
MAX_RECEIVE_COUNT=3
VISIBILITY_TIMEOUT=60       # segundos que el mensaje es invisible mientras se procesa
MSG_RETENTION=86400         # 24 horas para la queue principal
DLQ_RETENTION=1209600       # 14 dias para la DLQ

# ECS Workers
WORKER_SERVICE="shopapi-worker"
WORKER_TD_FILE="$(dirname "$0")/task-def-worker.json"

# Capacity Providers
CP_FARGATE_BASE=1
CP_FARGATE_WEIGHT=1
CP_SPOT_BASE=0
CP_SPOT_WEIGHT=3

# Auto Scaling workers
WORKER_MIN_CAPACITY=0
WORKER_MAX_CAPACITY=10
SQS_TARGET_BACKLOG=10       # mensajes por task = target del escalado

# CloudWatch namespace para metrica personalizada
CW_NAMESPACE="ShopAPI/Workers"
CW_METRICA="SQSBacklogPerTask"

# Modo de ejecucion
MODO="${1:-full}"

# =============================================================================
# Funcion: obtener recursos existentes
# =============================================================================
obtener_recursos() {
  log_info "Obteniendo recursos de la VPC y ECS..."

  VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=shopapi-vpc" \
    --query "Vpcs[0].VpcId" \
    --output text \
    --region "$REGION")

  PRIVATE_SUBNET_A=$(aws ec2 describe-subnets \
    --filters "Name=tag:Name,Values=shopapi-private-a" \
    --query "Subnets[0].SubnetId" \
    --output text \
    --region "$REGION")

  PRIVATE_SUBNET_B=$(aws ec2 describe-subnets \
    --filters "Name=tag:Name,Values=shopapi-private-b" \
    --query "Subnets[0].SubnetId" \
    --output text \
    --region "$REGION")

  PRIVATE_SUBNET_C=$(aws ec2 describe-subnets \
    --filters "Name=tag:Name,Values=shopapi-private-c" \
    --query "Subnets[0].SubnetId" \
    --output text \
    --region "$REGION")

  ECS_SG=$(aws ec2 describe-security-groups \
    --filters "Name=tag:Name,Values=shopapi-ecs-sg" \
    --query "SecurityGroups[0].GroupId" \
    --output text \
    --region "$REGION")

  log_info "VPC: $VPC_ID | SG: $ECS_SG"
  log_info "Subnets privadas: $PRIVATE_SUBNET_A | $PRIVATE_SUBNET_B | $PRIVATE_SUBNET_C"
}

# =============================================================================
# Funcion: obtener URLs de SQS (para modos secundarios)
# =============================================================================
obtener_urls_sqs() {
  QUEUE_URL=$(aws sqs get-queue-url \
    --queue-name "$QUEUE_NAME" \
    --query "QueueUrl" \
    --output text \
    --region "$REGION" 2>/dev/null) || log_error "Queue $QUEUE_NAME no encontrada. Ejecuta primero el modo full."

  DLQ_URL=$(aws sqs get-queue-url \
    --queue-name "$DLQ_NAME" \
    --query "QueueUrl" \
    --output text \
    --region "$REGION" 2>/dev/null) || log_error "DLQ $DLQ_NAME no encontrada."
}

# =============================================================================
# MODO: ENVIAR MENSAJES DE PRUEBA
# =============================================================================
if [[ "$MODO" == "--enviar-mensajes" ]]; then
  obtener_urls_sqs
  NUM_MENSAJES="${2:-50}"

  echo ""
  echo "============================================================"
  echo "  ENVIANDO $NUM_MENSAJES MENSAJES A SQS"
  echo "============================================================"
  echo "  Queue: $QUEUE_URL"
  echo "============================================================"
  echo ""

  for i in $(seq 1 "$NUM_MENSAJES"); do
    aws sqs send-message \
      --queue-url "$QUEUE_URL" \
      --message-body "{
        \"order_id\": \"ORD-$(date +%s)-$i\",
        \"customer_id\": \"CUST-$((RANDOM % 1000 + 1))\",
        \"items\": [{\"product_id\": \"P$(printf '%03d' $i)\", \"quantity\": $((RANDOM % 5 + 1))}],
        \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
        \"total\": $((RANDOM % 500 + 10)).99
      }" \
      --region "$REGION" \
      --output text > /dev/null
    echo -ne "\r  Enviado: $i / $NUM_MENSAJES"
  done

  echo ""
  echo ""
  log_info "Mensajes enviados. Estado de la cola:"
  aws sqs get-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --output table \
    --region "$REGION"

  echo ""
  echo "Monitorea el escalado con:"
  echo "  watch -n 10 'aws ecs describe-services --cluster $CLUSTER --services $WORKER_SERVICE \\"
  echo "    --query \"services[0].{D:desiredCount,R:runningCount,P:pendingCount}\" --output table'"

  exit 0
fi

# =============================================================================
# MODO: PUBLICAR METRICA CLOUDWATCH
# =============================================================================
if [[ "$MODO" == "--publicar-metrica" ]]; then
  obtener_urls_sqs
  ITERACIONES="${2:-10}"
  INTERVALO=30

  echo ""
  log_info "Publicando metrica $CW_METRICA cada ${INTERVALO}s ($ITERACIONES iteraciones)..."
  echo ""

  for i in $(seq 1 "$ITERACIONES"); do
    MSGS=$(aws sqs get-queue-attributes \
      --queue-url "$QUEUE_URL" \
      --attribute-names ApproximateNumberOfMessages \
      --query "Attributes.ApproximateNumberOfMessages" \
      --output text \
      --region "$REGION")

    RUNNING=$(aws ecs describe-services \
      --cluster "$CLUSTER" \
      --services "$WORKER_SERVICE" \
      --query "services[0].runningCount" \
      --output text \
      --region "$REGION")

    # Usar minimo 1 para evitar division por cero cuando no hay workers
    RUNNING_SAFE=$(( RUNNING > 0 ? RUNNING : 1 ))
    BACKLOG=$(echo "scale=4; $MSGS / $RUNNING_SAFE" | bc 2>/dev/null || echo "$MSGS")

    aws cloudwatch put-metric-data \
      --namespace "$CW_NAMESPACE" \
      --metric-name "$CW_METRICA" \
      --value "$BACKLOG" \
      --unit Count \
      --dimensions \
        Name=Service,Value="$WORKER_SERVICE" \
        Name=Queue,Value="$QUEUE_NAME" \
      --region "$REGION"

    echo "$(date '+%H:%M:%S') | Mensajes en cola: $MSGS | Workers activos: $RUNNING | Backlog/task: $BACKLOG"

    if [[ $i -lt $ITERACIONES ]]; then
      sleep "$INTERVALO"
    fi
  done

  echo ""
  log_info "Metrica publicada. El auto scaling tardara 1-2 minutos en reaccionar."
  exit 0
fi

# =============================================================================
# MODO: SIMULAR INTERRUPCION FARGATE SPOT
# =============================================================================
if [[ "$MODO" == "--simular-spot" ]]; then
  echo ""
  echo "============================================================"
  echo "  SIMULACION DE INTERRUPCION FARGATE SPOT"
  echo "============================================================"
  echo ""
  log_spot "Listando tasks del servicio worker con su Capacity Provider..."
  echo ""

  TASK_ARNS=$(aws ecs list-tasks \
    --cluster "$CLUSTER" \
    --service-name "$WORKER_SERVICE" \
    --query "taskArns" \
    --output text \
    --region "$REGION")

  if [[ -z "$TASK_ARNS" || "$TASK_ARNS" == "None" ]]; then
    log_error "No hay tasks en ejecucion en $WORKER_SERVICE. Envia mensajes primero."
  fi

  aws ecs describe-tasks \
    --cluster "$CLUSTER" \
    --tasks $TASK_ARNS \
    --query "tasks[*].{ID:taskArn,CP:capacityProviderName,AZ:availabilityZone,Estado:lastStatus}" \
    --output table \
    --region "$REGION"

  echo ""
  log_spot "Seleccionando el primer task para 'interrumpir'..."
  TASK_A_DETENER=$(echo "$TASK_ARNS" | awk '{print $1}')

  log_spot "Deteniendo task: $TASK_A_DETENER"
  log_spot "(Esto simula la señal SIGTERM de una interrupcion Spot)"
  echo ""

  aws ecs stop-task \
    --cluster "$CLUSTER" \
    --task "$TASK_A_DETENER" \
    --reason "Simulacion de interrupcion Fargate Spot - Lab v4" \
    --region "$REGION" \
    --query "task.{ID:taskArn,Estado:lastStatus}" \
    --output table

  echo ""
  log_spot "Task detenido. Observando recuperacion automatica..."
  echo ""

  for i in $(seq 1 8); do
    sleep 15
    INFO=$(aws ecs describe-services \
      --cluster "$CLUSTER" \
      --services "$WORKER_SERVICE" \
      --query "services[0].{D:desiredCount,R:runningCount,P:pendingCount}" \
      --output text \
      --region "$REGION")
    DESIRED=$(echo "$INFO" | awk '{print $1}')
    RUNNING=$(echo "$INFO" | awk '{print $2}')
    PENDING=$(echo "$INFO" | awk '{print $3}')
    echo "$(date '+%H:%M:%S') | T+$((i*15))s | desired=$DESIRED running=$RUNNING pending=$PENDING"
    if [[ "$RUNNING" == "$DESIRED" && "$PENDING" == "0" ]]; then
      echo ""
      log_spot "Recuperacion completada. ECS reemplazo el task automaticamente."
      break
    fi
  done

  echo ""
  echo "Lecciones aprendidas:"
  echo "  1. ECS detecto el task detenido y lanzo un reemplazo automaticamente"
  echo "  2. El mensaje de SQS permanecio invisible durante el visibility timeout ($VISIBILITY_TIMEOUT s)"
  echo "  3. Si el worker no proceso el mensaje antes de ser interrumpido, SQS lo reintentara"
  echo "  4. Tras $MAX_RECEIVE_COUNT intentos fallidos, el mensaje va a la DLQ"

  exit 0
fi

# =============================================================================
# MODO: CONFIGURACION COMPLETA (default)
# =============================================================================

obtener_recursos

echo ""
echo "============================================================"
echo "  CONFIGURANDO SQS + ECS WORKERS"
echo "============================================================"
echo "  Cuenta:   $ACCOUNT_ID"
echo "  Region:   $REGION"
echo "  Cluster:  $CLUSTER"
echo "============================================================"
echo ""

# -----------------------------------------------------------------------------
# Paso 1: Crear Dead Letter Queue
# -----------------------------------------------------------------------------
log_paso "Paso 1/7 — Creando Dead Letter Queue ($DLQ_NAME)..."

EXISTING_DLQ=$(aws sqs list-queues \
  --queue-name-prefix "$DLQ_NAME" \
  --query "QueueUrls[0]" \
  --output text \
  --region "$REGION" 2>/dev/null || echo "None")

if [[ "$EXISTING_DLQ" != "None" && -n "$EXISTING_DLQ" && "$EXISTING_DLQ" != "null" ]]; then
  log_warn "La DLQ ya existe: $EXISTING_DLQ"
  DLQ_URL="$EXISTING_DLQ"
else
  DLQ_URL=$(aws sqs create-queue \
    --queue-name "$DLQ_NAME" \
    --attributes "{
      \"MessageRetentionPeriod\": \"$DLQ_RETENTION\",
      \"VisibilityTimeout\": \"60\"
    }" \
    --tags "Proyecto=shopapi,Lab=v4,Componente=dlq" \
    --query "QueueUrl" \
    --output text \
    --region "$REGION")
  log_info "DLQ creada: $DLQ_URL"
fi

DLQ_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$DLQ_URL" \
  --attribute-names QueueArn \
  --query "Attributes.QueueArn" \
  --output text \
  --region "$REGION")

log_info "DLQ ARN: $DLQ_ARN"
log_info "  Retencion mensajes: 14 dias | maxReceiveCount: $MAX_RECEIVE_COUNT"

# -----------------------------------------------------------------------------
# Paso 2: Crear Queue principal con redrive policy
# -----------------------------------------------------------------------------
log_paso "Paso 2/7 — Creando Queue principal ($QUEUE_NAME) con redrive policy..."

EXISTING_Q=$(aws sqs list-queues \
  --queue-name-prefix "$QUEUE_NAME" \
  --query "QueueUrls[?ends_with(@, '/$QUEUE_NAME')]" \
  --output text \
  --region "$REGION" 2>/dev/null || echo "None")

# Escapar las comillas dobles para el JSON anidado de redrive policy
REDRIVE_POLICY="{\"deadLetterTargetArn\":\"$DLQ_ARN\",\"maxReceiveCount\":\"$MAX_RECEIVE_COUNT\"}"

if [[ -n "$EXISTING_Q" && "$EXISTING_Q" != "None" ]]; then
  log_warn "La queue ya existe: $EXISTING_Q"
  QUEUE_URL="$EXISTING_Q"
else
  QUEUE_URL=$(aws sqs create-queue \
    --queue-name "$QUEUE_NAME" \
    --attributes "{
      \"VisibilityTimeout\": \"$VISIBILITY_TIMEOUT\",
      \"MessageRetentionPeriod\": \"$MSG_RETENTION\",
      \"RedrivePolicy\": \"$(echo $REDRIVE_POLICY | sed 's/"/\\"/g')\"
    }" \
    --tags "Proyecto=shopapi,Lab=v4,Componente=orders-queue" \
    --query "QueueUrl" \
    --output text \
    --region "$REGION")
  log_info "Queue principal creada: $QUEUE_URL"
fi

QUEUE_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn \
  --query "Attributes.QueueArn" \
  --output text \
  --region "$REGION")

log_info "Queue ARN: $QUEUE_ARN"
log_info "  Visibility timeout: ${VISIBILITY_TIMEOUT}s | maxReceiveCount: $MAX_RECEIVE_COUNT | DLQ: $DLQ_ARN"

# Anadir permiso IAM al task role para acceder a SQS
TASK_ROLE_NAME="shopapi-task-role"
log_info "Añadiendo permisos SQS al Task Role ($TASK_ROLE_NAME)..."

aws iam put-role-policy \
  --role-name "$TASK_ROLE_NAME" \
  --policy-name shopapi-sqs-access \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": [
          \"sqs:ReceiveMessage\",
          \"sqs:DeleteMessage\",
          \"sqs:GetQueueAttributes\",
          \"sqs:ChangeMessageVisibility\"
        ],
        \"Resource\": [\"$QUEUE_ARN\", \"$DLQ_ARN\"]
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": \"sqs:SendMessage\",
        \"Resource\": \"$QUEUE_ARN\"
      }
    ]
  }" \
  --region "$REGION" 2>/dev/null || log_warn "No se pudo actualizar el Task Role (puede que ya tenga los permisos)"

# -----------------------------------------------------------------------------
# Paso 3: Inyectar variables en task-def-worker.json y registrar
# -----------------------------------------------------------------------------
log_paso "Paso 3/7 — Registrando Task Definition del worker..."

if [[ ! -f "$WORKER_TD_FILE" ]]; then
  log_error "No se encuentra task-def-worker.json en $WORKER_TD_FILE"
fi

# Sustituir placeholders en el JSON
TASK_DEF_TEMP=$(mktemp /tmp/shopapi-worker-td-XXXX.json)

sed \
  -e "s|PLACEHOLDER_ACCOUNT_ID|$ACCOUNT_ID|g" \
  -e "s|PLACEHOLDER_REGION|$REGION|g" \
  -e "s|PLACEHOLDER_QUEUE_URL|$QUEUE_URL|g" \
  "$WORKER_TD_FILE" > "$TASK_DEF_TEMP"

WORKER_TD_ARN=$(aws ecs register-task-definition \
  --cli-input-json "file://$TASK_DEF_TEMP" \
  --query "taskDefinition.taskDefinitionArn" \
  --output text \
  --region "$REGION")

rm -f "$TASK_DEF_TEMP"

log_info "Task Definition registrada: $WORKER_TD_ARN"

# -----------------------------------------------------------------------------
# Paso 4: Crear ECS Service del worker con Capacity Provider Strategy
# -----------------------------------------------------------------------------
log_paso "Paso 4/7 — Creando ECS Service $WORKER_SERVICE con Capacity Provider Strategy..."

echo ""
echo "  Estrategia de Capacity Providers:"
echo "  ┌────────────────────────────────────────┐"
echo "  │ FARGATE:      base=$CP_FARGATE_BASE weight=$CP_FARGATE_WEIGHT           │"
echo "  │ FARGATE_SPOT: base=$CP_SPOT_BASE    weight=$CP_SPOT_WEIGHT           │"
echo "  │                                        │"
echo "  │ Ejemplo 4 tasks nuevas:               │"
echo "  │   Task 1 → FARGATE      (base=1)      │"
echo "  │   Task 2 → FARGATE_SPOT (weight ratio) │"
echo "  │   Task 3 → FARGATE_SPOT               │"
echo "  │   Task 4 → FARGATE_SPOT               │"
echo "  │ → 75% FARGATE_SPOT = ~70% ahorro       │"
echo "  └────────────────────────────────────────┘"
echo ""

# Comprobar si el servicio ya existe
SERVICE_EXISTS=$(aws ecs describe-services \
  --cluster "$CLUSTER" \
  --services "$WORKER_SERVICE" \
  --query "services[?status=='ACTIVE'].serviceName" \
  --output text \
  --region "$REGION" 2>/dev/null || echo "")

if [[ -n "$SERVICE_EXISTS" ]]; then
  log_warn "El servicio $WORKER_SERVICE ya existe. Actualizando..."
  aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$WORKER_SERVICE" \
    --task-definition shopapi-worker \
    --region "$REGION" \
    --output text > /dev/null
  log_info "Servicio actualizado"
else
  aws ecs create-service \
    --cluster "$CLUSTER" \
    --service-name "$WORKER_SERVICE" \
    --task-definition shopapi-worker \
    --desired-count 0 \
    --capacity-provider-strategy \
      capacityProvider=FARGATE,base=$CP_FARGATE_BASE,weight=$CP_FARGATE_WEIGHT \
      capacityProvider=FARGATE_SPOT,base=$CP_SPOT_BASE,weight=$CP_SPOT_WEIGHT \
    --network-configuration "awsvpcConfiguration={
      subnets=[$PRIVATE_SUBNET_A,$PRIVATE_SUBNET_B,$PRIVATE_SUBNET_C],
      securityGroups=[$ECS_SG],
      assignPublicIp=DISABLED
    }" \
    --deployment-configuration '{
      "maximumPercent": 200,
      "minimumHealthyPercent": 100,
      "deploymentCircuitBreaker": {"enable": true, "rollback": true}
    }' \
    --tags key=Proyecto,value=shopapi key=Lab,value=v4 key=Componente,value=worker \
    --region "$REGION" \
    --output text > /dev/null

  log_info "Servicio $WORKER_SERVICE creado con desiredCount=0 (escalado por SQS)"
fi

# -----------------------------------------------------------------------------
# Paso 5: Registrar Scalable Target para los workers
# -----------------------------------------------------------------------------
log_paso "Paso 5/7 — Registrando Scalable Target para workers..."

aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id "service/$CLUSTER/$WORKER_SERVICE" \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity "$WORKER_MIN_CAPACITY" \
  --max-capacity "$WORKER_MAX_CAPACITY" \
  --region "$REGION"

log_info "Scalable target workers: min=$WORKER_MIN_CAPACITY max=$WORKER_MAX_CAPACITY"

# -----------------------------------------------------------------------------
# Paso 6: Crear Scaling Policy basada en SQSBacklogPerTask
# -----------------------------------------------------------------------------
log_paso "Paso 6/7 — Creando scaling policy Target Tracking (SQSBacklogPerTask = $SQS_TARGET_BACKLOG)..."

echo ""
echo "  Logica de escalado SQS:"
echo "  ┌─────────────────────────────────────────────┐"
echo "  │ target_value = mensajes_en_cola / workers   │"
echo "  │                                             │"
echo "  │ Ejemplo:                                    │"
echo "  │   Cola: 100 mensajes | Workers: 2           │"
echo "  │   Backlog/task = 100/2 = 50 > 10 → SCALE   │"
echo "  │   Nuevo count = ceil(100/10) = 10 workers   │"
echo "  └─────────────────────────────────────────────┘"
echo ""

aws application-autoscaling put-scaling-policy \
  --policy-name shopapi-workers-sqs-scaling \
  --service-namespace ecs \
  --resource-id "service/$CLUSTER/$WORKER_SERVICE" \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration "{
    \"TargetValue\": $SQS_TARGET_BACKLOG,
    \"CustomizedMetricSpecification\": {
      \"MetricName\": \"$CW_METRICA\",
      \"Namespace\": \"$CW_NAMESPACE\",
      \"Dimensions\": [
        {\"Name\": \"Service\", \"Value\": \"$WORKER_SERVICE\"},
        {\"Name\": \"Queue\", \"Value\": \"$QUEUE_NAME\"}
      ],
      \"Statistic\": \"Average\",
      \"Unit\": \"Count\"
    },
    \"ScaleOutCooldown\": 60,
    \"ScaleInCooldown\": 300,
    \"DisableScaleIn\": false
  }" \
  --region "$REGION"

log_info "Policy SQS scaling creada: target $SQS_TARGET_BACKLOG mensajes/worker"

# -----------------------------------------------------------------------------
# Paso 7: Verificar configuracion completa
# -----------------------------------------------------------------------------
log_paso "Paso 7/7 — Verificando configuracion completa..."

echo ""
echo "--- SQS Queues ---"
aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn VisibilityTimeout MessageRetentionPeriod RedrivePolicy \
  --output table \
  --region "$REGION"

echo ""
echo "--- ECS Service Worker ---"
aws ecs describe-services \
  --cluster "$CLUSTER" \
  --services "$WORKER_SERVICE" \
  --query "services[0].{Servicio:serviceName,Estado:status,Desired:desiredCount,Running:runningCount,CP:capacityProviderStrategy}" \
  --output table \
  --region "$REGION"

echo ""
echo "--- Scalable Target Workers ---"
aws application-autoscaling describe-scalable-targets \
  --service-namespace ecs \
  --resource-ids "service/$CLUSTER/$WORKER_SERVICE" \
  --query "ScalableTargets[0].{Min:MinCapacity,Max:MaxCapacity}" \
  --output table \
  --region "$REGION"

echo ""
echo "--- Scaling Policy Workers ---"
aws application-autoscaling describe-scaling-policies \
  --service-namespace ecs \
  --resource-id "service/$CLUSTER/$WORKER_SERVICE" \
  --query "ScalingPolicies[*].{Nombre:PolicyName,Tipo:PolicyType}" \
  --output table \
  --region "$REGION"

# -----------------------------------------------------------------------------
# Resumen final
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  SQS + WORKERS CONFIGURADOS"
echo "============================================================"
echo ""
echo "  SQS Queue:          $QUEUE_URL"
echo "  SQS DLQ:            $DLQ_URL"
echo "  Workers service:    $WORKER_SERVICE"
echo "  Capacity Providers: FARGATE(base=1) + FARGATE_SPOT(weight=3)"
echo "  Escalado:           SQSBacklogPerTask target=$SQS_TARGET_BACKLOG"
echo ""
echo "============================================================"
echo ""
echo "Prueba el escalado:"
echo ""
echo "  1. Enviar mensajes de prueba:"
echo "     bash 03-sqs-workers.sh --enviar-mensajes 50"
echo ""
echo "  2. Publicar metrica personalizada (en otra terminal):"
echo "     bash 03-sqs-workers.sh --publicar-metrica"
echo ""
echo "  3. Simular interrupcion Fargate Spot:"
echo "     bash 03-sqs-workers.sh --simular-spot"
echo ""
echo "  4. Monitorear workers:"
echo "     watch -n 10 'aws ecs describe-services --cluster $CLUSTER \\"
echo "       --services $WORKER_SERVICE \\"
echo "       --query \"services[0].{D:desiredCount,R:runningCount,P:pendingCount}\" \\"
echo "       --output table'"
echo ""
echo "Siguiente: revisar el README para la Fase A4 y validacion"
