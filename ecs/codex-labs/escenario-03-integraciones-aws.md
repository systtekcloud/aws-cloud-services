# Escenario 03 - Integraciones AWS alrededor de ECS

## Objetivo

Conectar el servicio ECS con servicios complementarios que aparecen frecuentemente en SAA:

- Secrets Manager (credenciales)
- CloudWatch (logs, metricas, alarmas)
- SQS (workers asincronos)
- DynamoDB (persistencia)
- EventBridge (event-driven)

## Paso 1 - Secrets Manager + Task Role

Crear secret:

```bash
aws secretsmanager create-secret \
  --name shopapi/prod/db \
  --secret-string '{"host":"db.internal","username":"shopapi","password":"cambiar"}' \
  --region ${AWS_REGION}
```

Actualizar Task Definition para usar `secrets`:

```json
"secrets": [
  {
    "name": "DB_PASSWORD",
    "valueFrom": "arn:aws:secretsmanager:eu-west-1:ACCOUNT_ID:secret:shopapi/prod/db:password::"
  }
]
```

### Resultado esperado

- El contenedor arranca sin credenciales hardcodeadas.
- En logs de app se ve conexion OK usando variable de entorno inyectada.

## Paso 2 - CloudWatch observabilidad

Crear alarmas basicas:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name shopapi-ecs-cpu-high \
  --metric-name CPUUtilization \
  --namespace AWS/ECS \
  --dimensions Name=ClusterName,Value=${CLUSTER_NAME} Name=ServiceName,Value=shopapi-service \
  --statistic Average \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --region ${AWS_REGION}
```

### Resultado esperado

- Alarmas creadas y estado inicial `OK`.
- Logs centralizados en `/ecs/shopapi-api`.

## Paso 3 - Patron API + Workers con SQS

Crear cola principal + DLQ:

```bash
DLQ_URL=$(aws sqs create-queue --queue-name shopapi-orders-dlq --query QueueUrl --output text --region ${AWS_REGION})
DLQ_ARN=$(aws sqs get-queue-attributes --queue-url ${DLQ_URL} --attribute-names QueueArn --query Attributes.QueueArn --output text --region ${AWS_REGION})

aws sqs create-queue \
  --queue-name shopapi-orders \
  --attributes "{\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"${DLQ_ARN}\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}" \
  --region ${AWS_REGION}
```

Crear `shopapi-worker` como segundo ECS Service (FARGATE_SPOT opcional).

### Resultado esperado

- Mensajes de pedidos entran en `shopapi-orders`.
- Worker consume mensajes.
- Mensajes fallidos pasan a DLQ tras 3 intentos.

## Paso 4 - DynamoDB para catalogo o estado de pedidos

```bash
aws dynamodb create-table \
  --table-name shopapi-products \
  --attribute-definitions AttributeName=product_id,AttributeType=S \
  --key-schema AttributeName=product_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ${AWS_REGION}
```

Concede permisos minimos al Task Role (`GetItem`, `PutItem`, `Query` segun uso).

### Resultado esperado

- API/worker puede leer y escribir en DynamoDB con IAM de minimo privilegio.

## Paso 5 - EventBridge para automatizaciones

Ejemplo: iniciar tarea batch nocturna.

```bash
aws events put-rule \
  --name shopapi-nightly-reconcile \
  --schedule-expression "cron(0 2 * * ? *)" \
  --state ENABLED \
  --region ${AWS_REGION}
```

Asocia como target un `RunTask` de ECS (task de reconciliacion).

### Resultado esperado

- Regla activa en EventBridge.
- Se ejecuta task programada en el horario definido.

## Validacion final del escenario

Checklist:

- Secret inyectado correctamente en ECS.
- Alarmas y logs operativos.
- Cola SQS y DLQ funcionando.
- Acceso de app a DynamoDB por Task Role.
- Evento programado en EventBridge.
