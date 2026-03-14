# Troubleshooting 01 — DynamoDB: Throttling y Hot Partitions

## Escenario

Observas errores en tu aplicación:

```
ProvisionedThroughputExceededException: The level of configured provisioned throughput for the table was exceeded.
```

O en los logs de Lambda (si usas Streams):

```
[ERROR] ProvisionedThroughputExceededException
```

O en CloudWatch: la alarma `dynamodb-ecommerce-read-throttle` / `write-throttle` se dispara.

---

## Diagnóstico

### Paso 1: Identificar el tipo de throttling

```bash
TABLE="ecommerce-orders"
START=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Read Throttle
aws cloudwatch get-metric-statistics \
  --namespace AWS/DynamoDB \
  --metric-name ReadThrottleEvents \
  --dimensions Name=TableName,Value=$TABLE \
  --start-time $START --end-time $END \
  --period 300 --statistics Sum \
  --region eu-west-1

# Write Throttle
aws cloudwatch get-metric-statistics \
  --namespace AWS/DynamoDB \
  --metric-name WriteThrottleEvents \
  --dimensions Name=TableName,Value=$TABLE \
  --start-time $START --end-time $END \
  --period 300 --statistics Sum \
  --region eu-west-1
```

Si los valores son > 0, hay throttling real.

### Paso 2: Verificar el modo de capacidad

```bash
aws dynamodb describe-table \
  --table-name $TABLE \
  --query 'Table.{BillingMode:BillingModeSummary.BillingMode,RCU:ProvisionedThroughput.ReadCapacityUnits,WCU:ProvisionedThroughput.WriteCapacityUnits}' \
  --output table --region eu-west-1
```

- Si `BillingMode=PAY_PER_REQUEST` → el throttling es muy inusual (solo en picos extremos el primer minuto)
- Si `BillingMode=PROVISIONED` → puede que hayas sobrepasado el límite

### Paso 3: Detectar Hot Partition (la causa más común de throttling en Provisioned)

Un hot partition ocurre cuando muchos requests van siempre al mismo PK.

**Síntoma en las métricas:**

```bash
# Consumed vs Provisioned Capacity
aws cloudwatch get-metric-statistics \
  --namespace AWS/DynamoDB \
  --metric-name ConsumedWriteCapacityUnits \
  --dimensions Name=TableName,Value=$TABLE \
  --start-time $START --end-time $END \
  --period 60 --statistics Sum \
  --region eu-west-1
```

Si el `Sum` se acerca al límite de WCU pero el tráfico debería estar distribuido, es señal de hot partition.

---

## Causas y soluciones

### Causa 1 — Partition Key con baja cardinalidad (Hot Partition)

**Ejemplo problemático:**
```
PK = "STATUS#active"   → Todos los usuarios activos en la misma partición
PK = "DATE#2024-01-15" → Todos los eventos del día en la misma partición
```

**Diagnóstico:**
```bash
# Si tienes este patrón, verás que un solo PK tiene miles de ítems
aws dynamodb query \
  --table-name $TABLE \
  --key-condition-expression "PK = :pk" \
  --expression-attribute-values '{":pk": {"S": "STATUS#active"}}' \
  --select COUNT \
  --region eu-west-1
# Count > 10000 → hot partition potencial
```

**Fix — Añadir sufijo aleatorio al PK (Write Sharding):**

```python
import random

# En lugar de PK = "STATUS#active"
# Usar PK = "STATUS#active#<shard>"
SHARD_COUNT = 10

def put_active_user(user_id, data):
    shard = random.randint(0, SHARD_COUNT - 1)
    pk = f"STATUS#active#{shard}"
    # PUT con el PK shardado
    table.put_item(Item={
        'PK': pk,
        'SK': f'USER#{user_id}',
        **data
    })

def get_all_active_users():
    # Para leer, hay que consultar todos los shards
    results = []
    for shard in range(SHARD_COUNT):
        pk = f"STATUS#active#{shard}"
        resp = table.query(
            KeyConditionExpression=Key('PK').eq(pk)
        )
        results.extend(resp['Items'])
    return results
```

### Causa 2 — Capacidad Provisionada insuficiente

**Fix — Aumentar RCU/WCU:**

```bash
aws dynamodb update-table \
  --table-name $TABLE \
  --provisioned-throughput ReadCapacityUnits=20,WriteCapacityUnits=20 \
  --region eu-west-1
```

**O cambiar a On-Demand (más simple para picos):**

```bash
aws dynamodb update-table \
  --table-name $TABLE \
  --billing-mode PAY_PER_REQUEST \
  --region eu-west-1
```

### Causa 3 — Autoscaling no reacciona a tiempo (burst de tráfico)

Provisioned Autoscaling puede tardar varios minutos en escalar. Durante ese tiempo, puede haber throttling.

**Fix en la app: implementar Exponential Backoff con Jitter:**

```python
import time, random, boto3
from botocore.exceptions import ClientError

def dynamo_put_with_retry(table, item, max_retries=5):
    for attempt in range(max_retries):
        try:
            table.put_item(Item=item)
            return
        except ClientError as e:
            if e.response['Error']['Code'] == 'ProvisionedThroughputExceededException':
                wait = (2 ** attempt) + random.uniform(0, 1)  # jitter
                print(f"Throttled. Retrying in {wait:.2f}s (attempt {attempt+1})")
                time.sleep(wait)
            else:
                raise
    raise Exception(f"Failed after {max_retries} retries")
```

**Nota:** El SDK de AWS hace retry automático con backoff, pero puede que la configuración por defecto no sea suficiente para picos muy grandes.

---

## Prevención

1. **Diseñar PK con alta cardinalidad** — IDs únicos, UUIDs, no fechas ni estados como PK.
2. **Usar On-Demand** para workloads con picos imprevisibles.
3. **Activar Autoscaling agresivo** (min=5, max=1000, target=50%) para no quedarse corto.
4. **Implementar retry con jitter** en la capa de aplicación.
5. **Usar DAX** (DynamoDB Accelerator) para cachear reads y reducir la carga sobre la tabla.

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|----------|-----------|
| ¿Qué es un Hot Partition? | Una partición que recibe desproporcionalmente más tráfico |
| ¿Solución al Hot Partition? | Write Sharding (añadir sufijo random al PK) |
| ¿`ProvisionedThroughputExceededException` en On-Demand? | Muy raro — solo en el primer minuto de burst extremo |
| ¿Qué solución AWS absorbe los picos de throttling en reads? | **DAX** |
