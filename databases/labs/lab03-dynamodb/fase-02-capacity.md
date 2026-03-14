# Fase 02 — DynamoDB: Capacity Modes, TTL y Alarmas

## Objetivo

Comparar On-Demand vs Provisioned+Autoscaling, configurar TTL para expiración automática de ítems, y entender las métricas de throttling que indican problemas de capacidad.

**Tiempo estimado:** 25-30 minutos
**Coste:** ~0 en On-Demand, centésimas con Provisioned en tabla de lab

---

## Parte A — On-Demand vs Provisioned: cuándo elegir cada modo

```
┌─────────────────────────────────────────────────────────────────────┐
│  ON-DEMAND                    │  PROVISIONED + AUTOSCALING          │
│  ─────────────────────────────│─────────────────────────────────────│
│  ✅ Picos imprevisibles        │  ✅ Carga predecible y constante     │
│  ✅ Nuevas aplicaciones        │  ✅ Menor coste si sabes el baseline  │
│  ✅ No administración RCU/WCU  │  ✅ Reserved Capacity disponible     │
│  ❌ Más caro por request       │  ❌ Throttling si subestimas         │
│     (~1.25x vs Provisioned)   │  ❌ Hay que monitorizar autoscaling  │
│                               │                                      │
│  Precio: ~$1.25/M read units  │  Precio: ~$0.00013/RCU·h            │
│          ~$1.25/M write units │          ~$0.00065/WCU·h            │
└─────────────────────────────────────────────────────────────────────┘
```

### Regla de decisión para el examen

| Escenario | Modo recomendado |
|-----------|-----------------|
| Tráfico variable, picos impredecibles | On-Demand |
| Tráfico estable y predecible | Provisioned |
| Workload de prueba / nuevo servicio | On-Demand |
| Workload con SLA de coste estricto | Provisioned + Autoscaling |
| DynamoDB como backend de Lambda (sporadic) | On-Demand |

---

## Paso 1 — Cambiar a modo Provisioned + Autoscaling

> Primero exploramos el modo Provisioned para entender los conceptos.

### Consola

1. **DynamoDB → Tables → ecommerce-orders → Additional settings tab**
2. Sección **Read/Write capacity mode** → **Edit**
3. Capacity mode: **Provisioned**
4. Read capacity:
   - Auto scaling: **On**
   - Minimum capacity units: `1`
   - Maximum capacity units: `10`
   - Target utilization: `70%`
5. Write capacity:
   - Auto scaling: **On**
   - Minimum: `1`, Maximum: `10`, Target: `70%`
6. **Save changes**

<details>
<summary>CLI equivalente</summary>

```bash
# Cambiar a Provisioned con Autoscaling
aws dynamodb update-table \
  --table-name ecommerce-orders \
  --billing-mode PROVISIONED \
  --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
  --region eu-west-1

# Registrar Application Autoscaling para Read
aws application-autoscaling register-scalable-target \
  --service-namespace dynamodb \
  --resource-id "table/ecommerce-orders" \
  --scalable-dimension "dynamodb:table:ReadCapacityUnits" \
  --min-capacity 1 \
  --max-capacity 10 \
  --region eu-west-1

# Política de escalado para Read (target 70%)
aws application-autoscaling put-scaling-policy \
  --service-namespace dynamodb \
  --resource-id "table/ecommerce-orders" \
  --scalable-dimension "dynamodb:table:ReadCapacityUnits" \
  --policy-name "ecommerce-orders-read-scaling" \
  --policy-type "TargetTrackingScaling" \
  --target-tracking-scaling-policy-configuration '{
    "TargetValue": 70.0,
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "DynamoDBReadCapacityUtilization"
    }
  }' \
  --region eu-west-1

# Registrar y configurar Write Autoscaling
aws application-autoscaling register-scalable-target \
  --service-namespace dynamodb \
  --resource-id "table/ecommerce-orders" \
  --scalable-dimension "dynamodb:table:WriteCapacityUnits" \
  --min-capacity 1 \
  --max-capacity 10 \
  --region eu-west-1

aws application-autoscaling put-scaling-policy \
  --service-namespace dynamodb \
  --resource-id "table/ecommerce-orders" \
  --scalable-dimension "dynamodb:table:WriteCapacityUnits" \
  --policy-name "ecommerce-orders-write-scaling" \
  --policy-type "TargetTrackingScaling" \
  --target-tracking-scaling-policy-configuration '{
    "TargetValue": 70.0,
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "DynamoDBWriteCapacityUtilization"
    }
  }' \
  --region eu-west-1
```

</details>

---

## Paso 2 — Volver a On-Demand (recomendado para labs)

Para el lab, el modo On-Demand es más económico (no hay RCU/WCU mínimos que pagar):

### Consola

1. **DynamoDB → Tables → ecommerce-orders → Additional settings**
2. **Edit** capacity mode → **On-demand**
3. **Save changes**

<details>
<summary>CLI equivalente</summary>

```bash
aws dynamodb update-table \
  --table-name ecommerce-orders \
  --billing-mode PAY_PER_REQUEST \
  --region eu-west-1
```

</details>

---

## Paso 3 — Configurar TTL (Time To Live)

TTL permite que DynamoDB **elimine automáticamente ítems expirados** sin consumir Write Capacity. Ideal para sesiones, cache, logs temporales.

### Entender TTL

```
Ítem:
{
  "PK": "SESSION#abc123",
  "SK": "USER#1001",
  "ttl": 1705363200,    ← Unix timestamp en segundos
  "datos_sesion": "..."
}

DynamoDB comprueba periódicamente el atributo TTL.
Cuando NOW() > ttl → elimina el ítem (en ~48h de la expiración)
```

### Consola

1. **DynamoDB → Tables → ecommerce-orders → Additional settings**
2. Sección **Time to Live (TTL)** → **Enable**
3. TTL attribute name: `ttl`
4. **Enable TTL**

<details>
<summary>CLI equivalente</summary>

```bash
aws dynamodb update-time-to-live \
  --table-name ecommerce-orders \
  --time-to-live-specification "Enabled=true,AttributeName=ttl" \
  --region eu-west-1

# Verificar
aws dynamodb describe-time-to-live \
  --table-name ecommerce-orders \
  --region eu-west-1
# TimeToLiveDescription.TimeToLiveStatus → ENABLED
```

</details>

### Insertar ítems con TTL

```bash
# Calcular timestamp de expiración: 1 minuto desde ahora (para ver TTL en acción)
TTL_1MIN=$(date -d '+1 minute' +%s)
# O en macOS: TTL_1MIN=$(date -v+1M +%s)

aws dynamodb put-item \
  --table-name ecommerce-orders \
  --item "{
    \"PK\": {\"S\": \"SESSION#abc123\"},
    \"SK\": {\"S\": \"USER#1001\"},
    \"ttl\": {\"N\": \"${TTL_1MIN}\"},
    \"datos\": {\"S\": \"Carrito temporal\"},
    \"tipo\": {\"S\": \"SESSION\"}
  }" \
  --region eu-west-1

echo "Ítem con TTL insertado. Expirará en 1 minuto (pero se eliminará en ~48h tras la expiración)."

# Para el lab, insertar con TTL en 2 días
TTL_2D=$(date -d '+2 days' +%s)
aws dynamodb put-item \
  --table-name ecommerce-orders \
  --item "{
    \"PK\": {\"S\": \"SESSION#xyz789\"},
    \"SK\": {\"S\": \"USER#1002\"},
    \"ttl\": {\"N\": \"${TTL_2D}\"},
    \"datos\": {\"S\": \"Sesión activa\"},
    \"tipo\": {\"S\": \"SESSION\"}
  }" \
  --region eu-west-1
```

> **Nota SAA-C03:** TTL tiene hasta 48h de delay después de la expiración. No es una eliminación instantánea. Si necesitas exclusión inmediata, filtra por `ttl > now()` en tu Query.

---

## Paso 4 — CloudWatch Alarm para Throttling

El throttling ocurre cuando las requests superan la capacidad provisionada. Es el indicador más importante de problemas de capacidad DynamoDB.

### Consola

1. **CloudWatch → Alarms → Create alarm**
2. **Select metric** → DynamoDB → Table Metrics → `SystemErrors` o `ThrottledRequests`
3. Seleccionar métrica: `ConsumedReadCapacityUnits` para la tabla `ecommerce-orders`
4. Conditions: **Greater than** threshold: `80` (80% de la RCU provisionada)
5. Alarm actions: SNS topic o email

<details>
<summary>CLI equivalente (alarma de throttling)</summary>

```bash
# Crear SNS topic para alertas
SNS_ARN=$(aws sns create-topic \
  --name dynamodb-lab03-alerts \
  --query 'TopicArn' --output text --region eu-west-1)

# Alarma: Read Throttle Events > 0 durante 5 min
aws cloudwatch put-metric-alarm \
  --alarm-name "dynamodb-ecommerce-read-throttle" \
  --alarm-description "DynamoDB Read Throttling detectado" \
  --metric-name ReadThrottleEvents \
  --namespace AWS/DynamoDB \
  --dimensions Name=TableName,Value=ecommerce-orders \
  --period 300 \
  --evaluation-periods 1 \
  --statistic Sum \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions $SNS_ARN \
  --region eu-west-1

# Alarma: Write Throttle Events
aws cloudwatch put-metric-alarm \
  --alarm-name "dynamodb-ecommerce-write-throttle" \
  --alarm-description "DynamoDB Write Throttling detectado" \
  --metric-name WriteThrottleEvents \
  --namespace AWS/DynamoDB \
  --dimensions Name=TableName,Value=ecommerce-orders \
  --period 300 \
  --evaluation-periods 1 \
  --statistic Sum \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions $SNS_ARN \
  --region eu-west-1

echo "Alarmas de throttling configuradas"
```

</details>

---

## ✅ Validaciones de la fase

```bash
# 1. Billing mode
aws dynamodb describe-table \
  --table-name ecommerce-orders \
  --query 'Table.BillingModeSummary.BillingMode' \
  --output text --region eu-west-1
# PAY_PER_REQUEST

# 2. TTL habilitado
aws dynamodb describe-time-to-live \
  --table-name ecommerce-orders \
  --query 'TimeToLiveDescription.TimeToLiveStatus' \
  --output text --region eu-west-1
# ENABLED

# 3. Alarmas creadas
aws cloudwatch describe-alarms \
  --alarm-names "dynamodb-ecommerce-read-throttle" "dynamodb-ecommerce-write-throttle" \
  --query 'MetricAlarms[*].{Name:AlarmName,State:StateValue}' \
  --output table --region eu-west-1

# 4. Items con TTL visibles
aws dynamodb query \
  --table-name ecommerce-orders \
  --key-condition-expression "PK = :pk" \
  --expression-attribute-values '{":pk": {"S": "SESSION#abc123"}}' \
  --region eu-west-1
# Debe mostrar el ítem con atributo ttl
```

---

## Conceptos SAA-C03 cubiertos

| Pregunta del examen | Respuesta |
|---------------------|-----------|
| ¿Qué modo usar para carga impredecible? | **On-Demand** |
| ¿Qué modo es más barato para carga predecible? | **Provisioned + Autoscaling** |
| ¿Qué hace TTL? | Elimina ítems automáticamente sin consumir WCU |
| ¿Cuánto tarda TTL en eliminar? | Hasta 48h después de la expiración |
| ¿Qué métrica indica throttling? | `ReadThrottleEvents` / `WriteThrottleEvents` |
| ¿Solución al throttling? | Aumentar RCU/WCU, cambiar a On-Demand, o revisar hot partitions |
