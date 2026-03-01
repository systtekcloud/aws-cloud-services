# Lab v4 — Alta Disponibilidad, Auto Scaling y Workers SQS

## Objetivo

Añadir elasticidad real a ShopAPI mediante:
- **Multi-AZ real**: expandir de 2 a 3 zonas de disponibilidad
- **Application Auto Scaling**: escalar la API según tráfico (ALB) y horario (Black Friday)
- **SQS + Workers ECS**: desacoplar el procesamiento de pedidos con una cola
- **Capacity Providers**: mezclar FARGATE + FARGATE_SPOT para optimizar costes (75% más barato en workers)
- **Resiliencia ante interrupciones Spot**: demostrar recuperación automática

**Examen SAA-C03**: este lab cubre escalado horizontal, desacoplamiento con SQS, spot interruptions y arquitecturas event-driven.

---

## Arquitectura

```
                              Internet
                                 │
                  ┌──────────────┼──────────────┐
                  │              │              │
               eu-west-1a   eu-west-1b   eu-west-1c
                  │              │              │
               [ALB Listener :80]
                  │
      ┌───────────┼───────────┐
  [ECS API]   [ECS API]   [ECS API]
   Fargate     Fargate     Fargate
  eu-west-1a  eu-west-1b  eu-west-1c
      │
      ├── POST /orders ──► [SQS Orders Queue]
                                │           └── [DLQ]
                           (maxReceiveCount=3)
                                │
                    ┌───────────┴────────────┐
                    │   ECS Workers          │
                    │   shopapi-worker       │
                    │   0 – 10 tasks         │
                    │   FARGATE 25%          │
                    │   FARGATE_SPOT 75%     │
                    └────────────────────────┘
```

### Distribución de Capacity Providers (matemática)

```
Estrategia para workers:
  FARGATE:      base=1, weight=1
  FARGATE_SPOT: base=0, weight=3

Ejemplo con 4 tasks:
  - Task 1: FARGATE      (cubre la base=1)
  - Task 2: FARGATE_SPOT (weight=3 → 3 de cada 4 van a SPOT)
  - Task 3: FARGATE_SPOT
  - Task 4: FARGATE_SPOT

Resultado: 1 FARGATE + 3 FARGATE_SPOT = 75% ahorro respecto a todo FARGATE
```

### Fórmula de escalado SQS

```
Métrica personalizada: SQS backlog por task

  target_value = mensajes_en_cola / tasks_en_ejecucion

Configuración: target_value = 10 mensajes por task

Ejemplo de escalado:
  Cola: 100 mensajes | Workers actuales: 2
  Backlog por task: 100 / 2 = 50  →  50 > 10  →  SCALE OUT

  Nuevo desiredCount = ceil(100 / 10) = 10 tasks

  Cola: 100 mensajes | Workers actuales: 10
  Backlog por task: 100 / 10 = 10  →  equilibrio alcanzado
```

---

## Prerrequisitos

- Lab v3 completado y funcionando
- ECS Cluster `shopapi-cluster` activo
- ALB `shopapi-alb` con Target Group configurado
- Secrets Manager con credenciales de la API
- IAM Task Role con permisos base
- Variables de entorno configuradas:

```bash
export AWS_DEFAULT_REGION=eu-west-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CLUSTER=shopapi-cluster
export VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=shopapi-vpc" \
  --query "Vpcs[0].VpcId" --output text)
export ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names shopapi-alb \
  --query "LoadBalancers[0].LoadBalancerArn" --output text)
export TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups \
  --names shopapi-tg \
  --query "TargetGroups[0].TargetGroupArn" --output text)
```

---

## Fase A1 — Expandir a 3 AZs (eu-west-1c)

### Contexto

La VPC actual tiene subnets en eu-west-1a y eu-west-1b. Añadiremos subnets en eu-west-1c para distribuir la carga en tres zonas.

| Subnet          | CIDR           | AZ          |
|-----------------|----------------|-------------|
| public-a        | 10.0.1.0/24    | eu-west-1a  |
| public-b        | 10.0.2.0/24    | eu-west-1b  |
| **public-c**    | **10.0.3.0/24**| **eu-west-1c** |
| private-a       | 10.0.11.0/24   | eu-west-1a  |
| private-b       | 10.0.12.0/24   | eu-west-1b  |
| **private-c**   | **10.0.13.0/24**| **eu-west-1c** |

### Pasos

**1. Crear subnet pública en eu-west-1c**

```bash
PUBLIC_SUBNET_C=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.3.0/24 \
  --availability-zone eu-west-1c \
  --query "Subnet.SubnetId" --output text)

aws ec2 create-tags \
  --resources $PUBLIC_SUBNET_C \
  --tags Key=Name,Value=shopapi-public-c Key=Tier,Value=public
```

**2. Crear subnet privada en eu-west-1c**

```bash
PRIVATE_SUBNET_C=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.13.0/24 \
  --availability-zone eu-west-1c \
  --query "Subnet.SubnetId" --output text)

aws ec2 create-tags \
  --resources $PRIVATE_SUBNET_C \
  --tags Key=Name,Value=shopapi-private-c Key=Tier,Value=private
```

**3. Habilitar auto-assign de IP pública en subnet publica-c**

```bash
aws ec2 modify-subnet-attribute \
  --subnet-id $PUBLIC_SUBNET_C \
  --map-public-ip-on-launch
```

**4. Asociar route table**

```bash
# Obtener la route table privada (que apunta al NAT Gateway)
PRIVATE_RTB=$(aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=shopapi-private-rtb" \
  --query "RouteTables[0].RouteTableId" --output text)

aws ec2 associate-route-table \
  --subnet-id $PRIVATE_SUBNET_C \
  --route-table-id $PRIVATE_RTB

# Route table pública
PUBLIC_RTB=$(aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=shopapi-public-rtb" \
  --query "RouteTables[0].RouteTableId" --output text)

aws ec2 associate-route-table \
  --subnet-id $PUBLIC_SUBNET_C \
  --route-table-id $PUBLIC_RTB
```

**5. Añadir subnet pública al ALB**

```bash
aws elbv2 set-subnets \
  --load-balancer-arn $ALB_ARN \
  --subnets $PUBLIC_SUBNET_A $PUBLIC_SUBNET_B $PUBLIC_SUBNET_C
```

**6. Actualizar ECS Service con la tercera subnet**

```bash
aws ecs update-service \
  --cluster $CLUSTER \
  --service shopapi-service \
  --network-configuration "awsvpcConfiguration={
    subnets=[$PRIVATE_SUBNET_A,$PRIVATE_SUBNET_B,$PRIVATE_SUBNET_C],
    securityGroups=[$ECS_SG],
    assignPublicIp=DISABLED
  }"
```

**7. Verificar distribución de tasks por AZ**

```bash
# Listar tasks con su AZ
aws ecs list-tasks --cluster $CLUSTER --service-name shopapi-service \
  --query "taskArns" --output text | tr '\t' '\n' | while read TASK_ARN; do
    aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK_ARN \
      --query "tasks[0].{TaskArn:taskArn,AZ:availabilityZone,Status:lastStatus}" \
      --output table
done
```

---

## Fase A2 — Auto Scaling de la API

### Contexto

Configuraremos tres mecanismos de escalado para la API:

| Mecanismo           | Métrica                    | Propósito                       |
|---------------------|----------------------------|---------------------------------|
| Target Tracking     | ALBRequestCountPerTarget   | Escalar según tráfico real      |
| Step Scaling        | CPUUtilization > 80%       | Guardrail secundario            |
| Scheduled Scaling   | Horario 20:00-22:00 UTC    | Pre-calentamiento Black Friday  |

### Pasos

**1. Registrar el scalable target**

```bash
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/shopapi-service \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 2 \
  --max-capacity 10
```

**2. Target Tracking — ALBRequestCountPerTarget**

```bash
# Obtener el sufijo del Target Group para la métrica de ALB
TG_SUFFIX=$(echo $TARGET_GROUP_ARN | sed 's/.*:targetgroup\//targetgroup\//')
ALB_SUFFIX=$(echo $ALB_ARN | sed 's/.*:loadbalancer\//loadbalancer\//')

aws application-autoscaling put-scaling-policy \
  --policy-name shopapi-api-target-tracking-alb \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/shopapi-service \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration "{
    \"TargetValue\": 500.0,
    \"PredefinedMetricSpecification\": {
      \"PredefinedMetricType\": \"ALBRequestCountPerTarget\",
      \"ResourceLabel\": \"$ALB_SUFFIX/$TG_SUFFIX\"
    },
    \"ScaleOutCooldown\": 60,
    \"ScaleInCooldown\": 300,
    \"DisableScaleIn\": false
  }"
```

> **Por que 500 requests por task?** Con FastAPI en Fargate 0.5 vCPU, ~500 req/min es el punto de saturacion. Por encima, la latencia sube >200ms. Este valor se ajusta empiricamente con el stress test.

**3. Step Scaling — CPU como guardrail**

```bash
# Crear alarma de CPU alta
aws cloudwatch put-metric-alarm \
  --alarm-name shopapi-api-cpu-high \
  --metric-name CPUUtilization \
  --namespace AWS/ECS \
  --dimensions Name=ClusterName,Value=$CLUSTER Name=ServiceName,Value=shopapi-service \
  --statistic Average \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --alarm-description "CPU de la API por encima del 80% durante 2 minutos"

# Crear la policy de Step Scaling
aws application-autoscaling put-scaling-policy \
  --policy-name shopapi-api-step-scaling-cpu \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/shopapi-service \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-type StepScaling \
  --step-scaling-policy-configuration "{
    \"AdjustmentType\": \"ChangeInCapacity\",
    \"StepAdjustments\": [
      {\"MetricIntervalLowerBound\": 0, \"MetricIntervalUpperBound\": 20, \"ScalingAdjustment\": 1},
      {\"MetricIntervalLowerBound\": 20, \"ScalingAdjustment\": 3}
    ],
    \"Cooldown\": 120
  }"
```

**4. Scheduled Action — Black Friday (pre-calentamiento)**

```bash
# Programar mínimo de 5 tasks de 20:00 a 22:00 UTC todos los viernes
# (ajusta la fecha para el próximo viernes de prueba)
aws application-autoscaling put-scheduled-action \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/shopapi-service \
  --scalable-dimension ecs:service:DesiredCount \
  --scheduled-action-name shopapi-black-friday-scale-out \
  --schedule "cron(0 20 ? * FRI *)" \
  --scalable-target-action MinCapacity=5,MaxCapacity=15

aws application-autoscaling put-scheduled-action \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/shopapi-service \
  --scalable-dimension ecs:service:DesiredCount \
  --scheduled-action-name shopapi-black-friday-scale-in \
  --schedule "cron(0 22 ? * FRI *)" \
  --scalable-target-action MinCapacity=2,MaxCapacity=10
```

### Stress test — Disparar el escalado

```bash
# Obtener el DNS del ALB
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names shopapi-alb \
  --query "LoadBalancers[0].DNSName" --output text)

# Lanzar 10 procesos en paralelo, cada uno enviando 1000 peticiones
echo "Iniciando stress test contra http://$ALB_DNS/health"
for i in $(seq 1 10); do
  (
    for j in $(seq 1 1000); do
      curl -s -o /dev/null "http://$ALB_DNS/health"
    done
    echo "Proceso $i completado"
  ) &
done
wait
echo "Stress test finalizado"

# Monitorear el escalado en tiempo real (en otra terminal)
watch -n 5 'aws ecs describe-services \
  --cluster shopapi-cluster \
  --services shopapi-service \
  --query "services[0].{Desired:desiredCount,Running:runningCount,Pending:pendingCount}" \
  --output table'
```

### Observar el escalado

```bash
# Ver historial de actividades de escalado
aws application-autoscaling describe-scaling-activities \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/shopapi-service \
  --query "ScalingActivities[*].{Tiempo:StartTime,Causa:Cause,Desc:Description}" \
  --output table

# Ver politicas activas
aws application-autoscaling describe-scaling-policies \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/shopapi-service \
  --output table
```

---

## Fase A3 — SQS + Workers ECS

### Contexto

La API publica mensajes en SQS al recibir pedidos. Los workers consumen esa cola de forma independiente, permitiendo:
- **Desacoplamiento**: la API responde inmediatamente al cliente
- **Elasticidad**: los workers escalan según la profundidad de la cola
- **Resiliencia**: los mensajes fallidos van a la DLQ para reintento manual

### Pasos

**1. Crear Dead Letter Queue (DLQ)**

```bash
DLQ_URL=$(aws sqs create-queue \
  --queue-name shopapi-orders-dlq \
  --attributes '{
    "MessageRetentionPeriod": "1209600",
    "Tags": {"Proyecto": "shopapi", "Lab": "v4"}
  }' \
  --query "QueueUrl" --output text)

DLQ_ARN=$(aws sqs get-queue-attributes \
  --queue-url $DLQ_URL \
  --attribute-names QueueArn \
  --query "Attributes.QueueArn" --output text)

echo "DLQ URL: $DLQ_URL"
echo "DLQ ARN: $DLQ_ARN"
```

**2. Crear Queue principal con redrive policy**

```bash
QUEUE_URL=$(aws sqs create-queue \
  --queue-name shopapi-orders \
  --attributes "{
    \"VisibilityTimeout\": \"60\",
    \"MessageRetentionPeriod\": \"86400\",
    \"RedrivePolicy\": \"{\\\"deadLetterTargetArn\\\":\\\"$DLQ_ARN\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"
  }" \
  --query "QueueUrl" --output text)

QUEUE_ARN=$(aws sqs get-queue-attributes \
  --queue-url $QUEUE_URL \
  --attribute-names QueueArn \
  --query "Attributes.QueueArn" --output text)

echo "Queue URL: $QUEUE_URL"
```

**3. Crear Task Definition del worker**

```bash
aws ecs register-task-definition \
  --cli-input-json file://task-def-worker.json
```

**4. Crear ECS Service del worker con Capacity Provider Strategy**

```bash
aws ecs create-service \
  --cluster $CLUSTER \
  --service-name shopapi-worker \
  --task-definition shopapi-worker \
  --desired-count 0 \
  --capacity-provider-strategy \
    capacityProvider=FARGATE,base=1,weight=1 \
    capacityProvider=FARGATE_SPOT,base=0,weight=3 \
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
  --tags key=Proyecto,value=shopapi key=Lab,value=v4
```

**5. Registrar scalable target para workers**

```bash
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/shopapi-worker \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 0 \
  --max-capacity 10
```

**6. Publicar métrica personalizada de backlog SQS**

Para escalar por "mensajes por worker", publicamos una métrica personalizada en CloudWatch:

```bash
# Script que calcula y publica la metrica cada minuto (ejecutar como daemon o en Lambda)
publish_sqs_backlog_metric() {
  MSGS=$(aws sqs get-queue-attributes \
    --queue-url $QUEUE_URL \
    --attribute-names ApproximateNumberOfMessages \
    --query "Attributes.ApproximateNumberOfMessages" --output text)

  RUNNING=$(aws ecs describe-services \
    --cluster $CLUSTER \
    --services shopapi-worker \
    --query "services[0].runningCount" --output text)

  # Evitar division por cero
  if [ "$RUNNING" -eq "0" ]; then
    RUNNING=1
  fi

  BACKLOG=$(echo "scale=2; $MSGS / $RUNNING" | bc)

  aws cloudwatch put-metric-data \
    --namespace ShopAPI/Workers \
    --metric-name SQSBacklogPerTask \
    --value $BACKLOG \
    --unit Count \
    --dimensions Service=shopapi-worker,Queue=shopapi-orders

  echo "Mensajes: $MSGS | Workers: $RUNNING | Backlog/task: $BACKLOG"
}

# Publicar cada 30 segundos durante 5 minutos
for i in $(seq 1 10); do
  publish_sqs_backlog_metric
  sleep 30
done
```

**7. Crear scaling policy para workers basada en SQS**

```bash
aws application-autoscaling put-scaling-policy \
  --policy-name shopapi-workers-sqs-scaling \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/shopapi-worker \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration "{
    \"TargetValue\": 10.0,
    \"CustomizedMetricSpecification\": {
      \"MetricName\": \"SQSBacklogPerTask\",
      \"Namespace\": \"ShopAPI/Workers\",
      \"Dimensions\": [
        {\"Name\": \"Service\", \"Value\": \"shopapi-worker\"},
        {\"Name\": \"Queue\", \"Value\": \"shopapi-orders\"}
      ],
      \"Statistic\": \"Average\"
    },
    \"ScaleOutCooldown\": 60,
    \"ScaleInCooldown\": 300,
    \"DisableScaleIn\": false
  }"
```

**8. Enviar mensajes de prueba y observar escalado**

```bash
# Enviar 50 mensajes de prueba a la cola
echo "Enviando 50 mensajes de prueba..."
for i in $(seq 1 50); do
  aws sqs send-message \
    --queue-url $QUEUE_URL \
    --message-body "{\"order_id\": \"ORD-$i\", \"items\": [\"item-$i\"], \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
done
echo "Mensajes enviados."

# Verificar profundidad de la cola
aws sqs get-queue-attributes \
  --queue-url $QUEUE_URL \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --output table

# Monitorear workers en tiempo real
watch -n 10 'echo "=== Workers ===" && \
  aws ecs describe-services --cluster shopapi-cluster --services shopapi-worker \
    --query "services[0].{Desired:desiredCount,Running:runningCount,Pending:pendingCount}" \
    --output table && \
  echo "=== Cola SQS ===" && \
  aws sqs get-queue-attributes \
    --queue-url $(aws sqs get-queue-url --queue-name shopapi-orders --query QueueUrl --output text) \
    --attribute-names ApproximateNumberOfMessages \
    --output table'
```

---

## Fase A4 — Simular interrupción de Fargate Spot

### Contexto: Ciclo de vida de una interrupcion Spot

Cuando AWS necesita recuperar capacidad Spot, el proceso es:

```
1. AWS envia señal de interrupcion (2 minutos de aviso)
2. ECS recibe SIGTERM al container (termination notice)
3. El container tiene 30 segundos para hacer graceful shutdown
4. Si no para: SIGKILL
5. ECS detecta que el task paró
6. ECS lanza un task nuevo en otra AZ o en FARGATE base
```

**Buenas practicas para idempotencia:**
- Usar `visibility timeout` en SQS: si el worker muere, el mensaje vuelve a la cola tras X segundos
- Guardar el estado del procesamiento en DynamoDB antes de confirmar el mensaje
- Usar `ReceiptHandle` para eliminar el mensaje solo al finalizar con exito

### Simular la interrupción

```bash
# Listar tasks del worker y sus Capacity Providers
aws ecs list-tasks --cluster $CLUSTER --service-name shopapi-worker \
  --query "taskArns" --output text | tr '\t' '\n' | while read TASK_ARN; do
    aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK_ARN \
      --query "tasks[0].{ID:taskArn,CP:capacityProviderName,AZ:availabilityZone}" \
      --output table
done

# Seleccionar un task FARGATE_SPOT para "interrumpir"
SPOT_TASK=$(aws ecs list-tasks --cluster $CLUSTER --service-name shopapi-worker \
  --query "taskArns[0]" --output text)

echo "Deteniendo task: $SPOT_TASK"
aws ecs stop-task \
  --cluster $CLUSTER \
  --task $SPOT_TASK \
  --reason "Simulacion de interrupcion Fargate Spot"

# Observar reemplazo automatico (ECS lanza nuevo task en ~30-60 segundos)
echo "Esperando reemplazo automatico..."
for i in $(seq 1 10); do
  sleep 15
  aws ecs describe-services \
    --cluster $CLUSTER \
    --services shopapi-worker \
    --query "services[0].{Desired:desiredCount,Running:runningCount,Pending:pendingCount}" \
    --output table
done
```

### ¿Qué observar?

| Momento | runningCount | pendingCount | Descripcion |
|---------|-------------|--------------|-------------|
| T+0s    | 2           | 0            | Estado inicial |
| T+5s    | 1           | 1            | Task detenido, nuevo iniciandose |
| T+30s   | 2           | 0            | Recuperado automaticamente |

---

## Validación completa del Lab

### 1. Verificar distribución multi-AZ

```bash
echo "=== Distribucion de tasks de la API por AZ ==="
TASK_ARNS=$(aws ecs list-tasks \
  --cluster $CLUSTER \
  --service-name shopapi-service \
  --query "taskArns" --output text)

aws ecs describe-tasks \
  --cluster $CLUSTER \
  --tasks $TASK_ARNS \
  --query "tasks[*].{AZ:availabilityZone,Status:lastStatus,CP:capacityProviderName}" \
  --output table
```

### 2. Verificar que el ALB tiene 3 AZs

```bash
aws elbv2 describe-load-balancers \
  --names shopapi-alb \
  --query "LoadBalancers[0].AvailabilityZones[*].{AZ:ZoneName,Subnet:SubnetId}" \
  --output table
```

### 3. Test de salud de la API

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names shopapi-alb \
  --query "LoadBalancers[0].DNSName" --output text)

# Verificar que la API responde
curl -v "http://$ALB_DNS/health"

# Verificar endpoint de orders (para comprobar publicacion en SQS)
curl -X POST "http://$ALB_DNS/orders" \
  -H "Content-Type: application/json" \
  -d '{"items": [{"product_id": "P001", "quantity": 2}]}'
```

### 4. Verificar políticas de Auto Scaling activas

```bash
echo "=== Politicas de la API ==="
aws application-autoscaling describe-scaling-policies \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/shopapi-service \
  --query "ScalingPolicies[*].{Nombre:PolicyName,Tipo:PolicyType,Estado:PolicyStatus}" \
  --output table

echo "=== Politicas de Workers ==="
aws application-autoscaling describe-scaling-policies \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/shopapi-worker \
  --query "ScalingPolicies[*].{Nombre:PolicyName,Tipo:PolicyType,Estado:PolicyStatus}" \
  --output table
```

### 5. Verificar Capacity Provider del worker

```bash
aws ecs describe-services \
  --cluster $CLUSTER \
  --services shopapi-worker \
  --query "services[0].capacityProviderStrategy" \
  --output table
```

---

## Troubleshooting

### Escenario 1: Workers escalan por CPU en vez de por SQS

**Síntoma**: Los workers tienen alta CPU pero la cola de SQS no decrece.

**Causa**: Se configuró escalado por CPU en lugar de por la métrica personalizada `SQSBacklogPerTask`.

**Diagnóstico**:
```bash
# Verificar qué métrica usa la policy
aws application-autoscaling describe-scaling-policies \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/shopapi-worker \
  --query "ScalingPolicies[0].TargetTrackingScalingPolicyConfiguration" \
  --output json
```

**Solución**: Eliminar la policy incorrecta y crear la correcta con `CustomizedMetricSpecification` apuntando a `SQSBacklogPerTask`. El escalado por CPU reacciona tarde (los workers ya están saturados) y no refleja el estado de la cola.

---

### Escenario 2: Fargate Spot interrumpido con trabajo perdido

**Síntoma**: Al detener un task Spot, los mensajes que estaba procesando desaparecen o se duplican.

**Causa**: El worker elimina el mensaje de SQS al recibirlo (`DeleteMessage` inmediato) en lugar de al finalizar el procesamiento.

**Diagnóstico**:
```bash
# Verificar profundidad de la DLQ tras una interrupcion
aws sqs get-queue-attributes \
  --queue-url $DLQ_URL \
  --attribute-names ApproximateNumberOfMessages
```

**Solución**: El patrón correcto es:
1. `ReceiveMessage` → visibility timeout = 60s (tiempo máximo de procesamiento)
2. Procesar el mensaje
3. Si OK → `DeleteMessage`
4. Si falla → dejar que expire el visibility timeout (el mensaje vuelve a la cola)
5. Tras 3 intentos (maxReceiveCount) → va a la DLQ

```python
# Patron correcto en el worker
mensaje = sqs.receive_message(QueueUrl=QUEUE_URL, MaxNumberOfMessages=1)
if 'Messages' in mensaje:
    body = mensaje['Messages'][0]
    receipt = body['ReceiptHandle']
    try:
        procesar_pedido(body['Body'])
        sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=receipt)
    except Exception as e:
        # No eliminamos: SQS reintentará automáticamente
        logger.error(f"Error procesando mensaje: {e}")
```

---

### Escenario 3: El escalado no ocurre porque desiredCount está en el mínimo

**Síntoma**: Se envían mensajes a SQS pero los workers no escalan.

**Causa**: El `desiredCount` del servicio es 0, y la métrica `SQSBacklogPerTask` no se puede calcular (división por cero). La métrica no se publica o publica 0.

**Diagnóstico**:
```bash
# Verificar que la metrica personalizada tiene datos
aws cloudwatch get-metric-statistics \
  --namespace ShopAPI/Workers \
  --metric-name SQSBacklogPerTask \
  --dimensions Name=Service,Value=shopapi-worker \
  --start-time $(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Average

# Verificar runningCount del servicio
aws ecs describe-services --cluster $CLUSTER --services shopapi-worker \
  --query "services[0].runningCount"
```

**Solución**: Cuando `runningCount == 0`, usar `running = 1` como denominador mínimo al publicar la métrica. Así:
- 50 mensajes / 1 (mínimo) = 50 → escala hasta 5 tasks
- Los tasks arrancan y empiezan a consumir

También considera usar `min-capacity 1` durante horas de posible actividad.

---

## Limpieza

```bash
# Ejecutar el script de limpieza completo
bash /home/sergi/DevOpsProjects/aws/services/ecs/labs/v4-autoscaling-multiz/cli/99-cleanup.sh
```

O manualmente en orden:

```bash
# 1. Eliminar scaling policies de workers
aws application-autoscaling delete-scaling-policy \
  --policy-name shopapi-workers-sqs-scaling \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/shopapi-worker \
  --scalable-dimension ecs:service:DesiredCount

aws application-autoscaling deregister-scalable-target \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/shopapi-worker \
  --scalable-dimension ecs:service:DesiredCount

# 2. Eliminar scaling policies de la API
aws application-autoscaling delete-scaling-policy \
  --policy-name shopapi-api-target-tracking-alb \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/shopapi-service \
  --scalable-dimension ecs:service:DesiredCount

aws application-autoscaling delete-scaling-policy \
  --policy-name shopapi-api-step-scaling-cpu \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/shopapi-service \
  --scalable-dimension ecs:service:DesiredCount

aws application-autoscaling delete-scheduled-action \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/shopapi-service \
  --scalable-dimension ecs:service:DesiredCount \
  --scheduled-action-name shopapi-black-friday-scale-out

aws application-autoscaling delete-scheduled-action \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/shopapi-service \
  --scalable-dimension ecs:service:DesiredCount \
  --scheduled-action-name shopapi-black-friday-scale-in

aws application-autoscaling deregister-scalable-target \
  --service-namespace ecs \
  --resource-id service/$CLUSTER/shopapi-service \
  --scalable-dimension ecs:service:DesiredCount

# 3. Detener y eliminar servicio de workers
aws ecs update-service --cluster $CLUSTER --service shopapi-worker --desired-count 0
sleep 30
aws ecs delete-service --cluster $CLUSTER --service shopapi-worker

# 4. Eliminar SQS
aws sqs delete-queue --queue-url $QUEUE_URL
aws sqs delete-queue --queue-url $DLQ_URL

# 5. Quitar subnet AZ-c del ECS Service (volver a 2 subnets)
aws ecs update-service \
  --cluster $CLUSTER \
  --service shopapi-service \
  --network-configuration "awsvpcConfiguration={
    subnets=[$PRIVATE_SUBNET_A,$PRIVATE_SUBNET_B],
    securityGroups=[$ECS_SG],
    assignPublicIp=DISABLED
  }"

# 6. Quitar subnet AZ-c del ALB
aws elbv2 set-subnets \
  --load-balancer-arn $ALB_ARN \
  --subnets $PUBLIC_SUBNET_A $PUBLIC_SUBNET_B

# 7. Eliminar subnets AZ-c
PRIVATE_SUBNET_C=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=shopapi-private-c" \
  --query "Subnets[0].SubnetId" --output text)
PUBLIC_SUBNET_C=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=shopapi-public-c" \
  --query "Subnets[0].SubnetId" --output text)

aws ec2 delete-subnet --subnet-id $PRIVATE_SUBNET_C
aws ec2 delete-subnet --subnet-id $PUBLIC_SUBNET_C

echo "Limpieza v4 completada"
```

---

## Conceptos clave para el examen SAA-C03

| Concepto | Detalle |
|----------|---------|
| **Application Auto Scaling** | Servicio centralizado para escalar ECS, DynamoDB, Aurora, etc. No confundir con EC2 Auto Scaling Groups |
| **Target Tracking** | AWS calcula automáticamente cuántas tasks añadir/quitar para mantener la métrica en el target |
| **Step Scaling** | Escala en pasos definidos manualmente; útil como guardrail o para métricas no soportadas por Target Tracking |
| **Scheduled Scaling** | Pre-calienta capacidad antes de eventos conocidos; no reactivo sino proactivo |
| **FARGATE_SPOT** | Hasta 70% más barato; puede ser interrumpido con 2 minutos de aviso; ideal para workloads tolerantes a fallos |
| **Capacity Provider Strategy** | Define la mezcla de FARGATE y FARGATE_SPOT; `base` garantiza ese número en FARGATE, `weight` define la proporción del resto |
| **SQS Visibility Timeout** | Tiempo que un mensaje está "invisible" mientras se procesa; si el worker falla, el mensaje reaparece tras ese tiempo |
| **Dead Letter Queue** | Recibe mensajes que fallaron N veces (maxReceiveCount); permite analizar errores sin perder datos |
| **Backlog per task** | Métrica clave para workers SQS: `mensajes_en_cola / workers_activos`; refleja la carga real por worker |
