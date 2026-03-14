# Troubleshooting 03 — Integración Multi-Servicio: Fallos en el Stack 3-Tier

## Escenario

El lab05 integra Aurora + RDS Proxy + DynamoDB + Redis + Lambda. Los fallos de integración son más difíciles de diagnosticar porque el error en un servicio puede manifestarse en otro.

Este documento cubre los patrones de fallo más frecuentes en arquitecturas multi-servicio.

---

## Árbol de diagnóstico por síntoma

```
¿Qué falla?
├── App no puede conectar a la DB
│   ├── Timeout TCP         → SG / VPC Routing
│   ├── Auth failed         → Secret incorrecto / usuario bloqueado
│   └── Too many connections → Usar RDS Proxy
├── Datos desactualizados en cache
│   ├── TTL largo           → Reducir TTL o invalidar explícitamente
│   └── Sin invalidación    → Añadir DEL tras UPDATE en DB
├── Lambda no procesa Streams
│   ├── ESM deshabilitado   → Verificar EventSourceMapping
│   ├── Error en código     → Ver CloudWatch Logs
│   └── IAM permissions     → AWSLambdaDynamoDBExecutionRole
└── Latencia alta en lectura
    ├── Cache miss rate alto → Ver Redis CacheHitRate
    ├── Consulta full scan   → Añadir GSI o usar Query
    └── Proxy overhead      → Comparar directo vs Proxy
```

---

## Problema 1 — Cache y DB inconsistentes (stale cache)

**Síntoma:** El precio de un producto en Redis difiere del precio en Aurora.

**Diagnóstico:**

```python
import redis
import boto3
import json

r = redis.Redis(host=REDIS_PRIMARY, port=6379, ssl=True)
ddb = boto3.resource("dynamodb", region_name="eu-west-1")
table = ddb.Table("ecommerce-catalog")

# Valor en Redis
redis_val = r.get("product:prod-001")
print("Redis:", json.loads(redis_val) if redis_val else "MISS")

# Valor en DynamoDB
ddb_val = table.get_item(Key={"PK": "PRODUCT#prod-001", "SK": "METADATA"})
print("DynamoDB:", ddb_val.get("Item", {}).get("precio"))
```

**Fix — invalidar Redis al actualizar DynamoDB:**

```python
def update_product_price(product_id, new_price):
    table = boto3.resource("dynamodb").Table("ecommerce-catalog")
    r = redis.Redis(host=REDIS_PRIMARY, port=6379, ssl=True)

    # 1. Actualizar en DynamoDB (fuente de verdad)
    table.update_item(
        Key={"PK": f"PRODUCT#{product_id}", "SK": "METADATA"},
        UpdateExpression="SET precio = :p",
        ExpressionAttributeValues={":p": Decimal(str(new_price))}
    )
    # 2. Invalidar caché → próxima lectura hará MISS → irá a DDB
    r.delete(f"product:{product_id}")
    print(f"Precio actualizado y caché invalidada para {product_id}")
```

---

## Problema 2 — Lambda no recibe eventos del Stream

**Síntoma:** Se insertan items en DynamoDB pero Lambda no se invoca (no hay logs en CloudWatch).

**Diagnóstico paso a paso:**

```bash
# 1. Verificar que el Stream está habilitado
aws dynamodb describe-table --table-name ecommerce-catalog \
  --query 'Table.StreamSpecification' --output json --region eu-west-1

# 2. Verificar el Event Source Mapping
aws lambda list-event-source-mappings \
  --function-name ecommerce-catalog-stream \
  --query 'EventSourceMappings[*].{State:State,BatchSize:BatchSize,StartPos:StartingPosition}' \
  --output table --region eu-west-1

# 3. Estado debe ser "Enabled". Si es "Disabled":
ESM_UUID=$(aws lambda list-event-source-mappings \
  --function-name ecommerce-catalog-stream \
  --query 'EventSourceMappings[0].UUID' --output text --region eu-west-1)
aws lambda update-event-source-mapping --uuid $ESM_UUID --enabled --region eu-west-1

# 4. Verificar logs de Lambda (últimos 5 min)
LOG_GROUP="/aws/lambda/ecommerce-catalog-stream"
aws logs filter-log-events \
  --log-group-name $LOG_GROUP \
  --start-time $(( $(date +%s) * 1000 - 300000 )) \
  --query 'events[*].message' --output text --region eu-west-1
```

**Fix — Problema de permisos IAM:**

```bash
# Verificar que el rol tiene AWSLambdaDynamoDBExecutionRole
aws iam list-attached-role-policies \
  --role-name lambda-lab05-role \
  --query 'AttachedPolicies[*].PolicyName' --output table

# Si falta, añadirla
aws iam attach-role-policy --role-name lambda-lab05-role \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaDynamoDBExecutionRole"
```

---

## Problema 3 — El ESM tiene errores pero Lambda funciona individualmente

**Síntoma:** CloudWatch muestra `IteratorAge` muy alto o `FailedRecordCount > 0`.

```bash
# Ver métricas del ESM
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name IteratorAge \
  --dimensions Name=FunctionName,Value=ecommerce-catalog-stream \
  --start-time $(date -u -d '30 min ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 --statistics Maximum \
  --output table --region eu-west-1
```

`IteratorAge` alto significa que Lambda tiene retraso procesando el Stream. Causas:
- Lambda con timeout muy bajo
- Error en código que hace reintentos
- Concurrencia de Lambda al límite

**Fix — Ver errores en el código Lambda:**

```bash
# Buscar errores en logs
aws logs filter-log-events \
  --log-group-name /aws/lambda/ecommerce-catalog-stream \
  --filter-pattern "ERROR" \
  --query 'events[*].message' --output text --region eu-west-1
```

---

## Problema 4 — Aurora failover: la app sigue conectada al Writer caído

**Síntoma:** Tras un failover de Aurora, las conexiones existentes devuelven error durante varios segundos/minutos.

**Por qué ocurre:**
- Sin RDS Proxy: la app mantiene conexiones TCP al Writer antiguo → error hasta reconectar al nuevo Writer
- Con RDS Proxy: el Proxy detecta el failover y redirige automáticamente → ~30-60s de interrupciones nuevas conexiones

**Fix en la app — Retry con backoff:**

```python
import time
import random
import mysql.connector
from mysql.connector import Error

def get_db_connection_with_retry(max_retries=5):
    """Conecta al Proxy con retry exponencial en caso de failover."""
    for attempt in range(max_retries):
        try:
            conn = mysql.connector.connect(
                host=PROXY_ENDPOINT,
                port=3306,
                user="admin",
                password=get_secret()["password"],
                database="ecommerce",
                connection_timeout=10
            )
            return conn
        except Error as e:
            if attempt == max_retries - 1:
                raise
            wait = (2 ** attempt) + random.uniform(0, 1)
            print(f"Conexión fallida (intento {attempt+1}): {e}. Reintentando en {wait:.1f}s")
            time.sleep(wait)
```

**Simular failover para probar el retry:**

```bash
aws rds failover-db-cluster \
  --db-cluster-identifier aurora-lab05 \
  --region eu-west-1

# Monitorizar cambio de Writer
OLD_WRITER=$(aws rds describe-db-clusters \
  --db-cluster-identifier aurora-lab05 \
  --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter==`true`].DBInstanceIdentifier | [0]' \
  --output text --region eu-west-1)
echo "Writer antes del failover: $OLD_WRITER"

for i in $(seq 1 20); do
  sleep 10
  CURRENT_WRITER=$(aws rds describe-db-clusters \
    --db-cluster-identifier aurora-lab05 \
    --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter==`true`].DBInstanceIdentifier | [0]' \
    --output text --region eu-west-1)
  echo "$(date '+%H:%M:%S') Writer actual: $CURRENT_WRITER"
  [[ "$CURRENT_WRITER" != "$OLD_WRITER" ]] && { echo "✅ Failover completado"; break; }
done
```

---

## Problema 5 — DynamoDB Streams: eventos duplicados o procesamiento incompleto

**Síntoma:** Lambda procesa el mismo evento dos veces, o algunos eventos se pierden.

**Por qué ocurre:**
- Lambda puede recibir el mismo batch hasta `maximum_retry_attempts` veces si hay error
- `TRIM_HORIZON` reprocesa todos los eventos desde el inicio del Stream (24h)

**Fix — Hacer Lambda idempotente:**

```python
import boto3
import json

ddb = boto3.resource("dynamodb")
processed_table = ddb.Table("lambda-processed-events")  # tabla auxiliar

def lambda_handler(event, context):
    for record in event["Records"]:
        sequence_number = record["dynamodb"]["SequenceNumber"]

        # Verificar si ya procesamos este evento
        try:
            processed_table.put_item(
                Item={"sequence_number": sequence_number},
                ConditionExpression="attribute_not_exists(sequence_number)"
            )
        except processed_table.meta.client.exceptions.ConditionalCheckFailedException:
            print(f"Evento {sequence_number} ya procesado, omitiendo")
            continue

        # Procesar el evento...
        process_record(record)
```

> **Tradeoff:** Añade latencia y coste por cada evento. Solo usar cuando la idempotencia sea crítica.

---

## Resumen SAA-C03 — Integración Multi-Servicio

| Patrón | Problema que resuelve | Servicio AWS |
|--------|----------------------|--------------|
| Cache-Aside | Reducir lecturas a RDS/Aurora | ElastiCache Redis |
| RDS Proxy | Too many connections (Lambda→Aurora) | RDS Proxy |
| Gateway Endpoint | DynamoDB/S3 sin salir a internet | VPC Endpoint |
| DynamoDB Streams + Lambda | Procesamiento de eventos async | Lambda + SNS |
| Retry + backoff | Resiliencia ante failover de Aurora | App code |
| Invalidación explícita | Consistencia cache-DB | Redis DEL |

> **Tip del examen:** Cuando el escenario tiene Lambda + Aurora, siempre proponer RDS Proxy. Cuando hay procesamiento de eventos, pensar en DynamoDB Streams → Lambda → SNS/SQS.
