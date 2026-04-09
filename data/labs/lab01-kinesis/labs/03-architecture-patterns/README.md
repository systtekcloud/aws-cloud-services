# Lab 03 — Patrones de arquitectura con Kinesis

> **Duración estimada:** 20 minutos (lectura + comandos de prueba)

---

## Objetivo

Entender 3 patrones reales donde Kinesis resuelve problemas que SQS o polling no pueden resolver bien. Cada patrón incluye diagrama ASCII y comandos CLI para verificar el concepto.

---

## Patrón 1: IoT → KDS → múltiples consumers simultáneos

**Caso:** 1.000 sensores IoT envían temperatura cada segundo. Necesitas:
- Sistema de alertas (Lambda) que detecta anomalías en tiempo real
- Sistema de archivo (Firehose → S3) para análisis histórico
- Dashboard (Kinesis Data Analytics) con métricas agregadas por minuto

**Por qué KDS:** Un solo stream, tres consumers independientes. Cada uno lee a su velocidad sin afectar a los otros. Con SQS, el primer consumer que lee el mensaje lo consume y los demás no lo ven.

```
1.000 sensores IoT
        │
        ▼  (put-record, PartitionKey = deviceId)
Kinesis Data Streams
  [shard-000] [shard-001] [shard-002]
        │           │           │
   ┌────┤      ┌────┤      ┌────┤
   │    │      │    │      │    │
   ▼    ▼      ▼    ▼      ▼    ▼
Lambda  Firehose  KDA
(alertas) (→S3) (dashboard)

Cada consumer tiene su propio shard iterator.
Leer no destruye el record — retención 24h+.
```

**Comandos de prueba:**

```bash
# Crear stream IoT simulado
aws kinesis create-stream \
  --stream-name iot-sensors \
  --shard-count 3 \
  --region eu-west-1

# Simular 5 sensores enviando datos
for device in sensor-{001..005}; do
  TEMP=$(echo "scale=1; $((RANDOM % 400 + 150)) / 10" | bc)
  aws kinesis put-record \
    --stream-name iot-sensors \
    --partition-key "$device" \
    --data "$(echo -n "{\"device\":\"$device\",\"temp\":$TEMP,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" | base64)" \
    --region eu-west-1 > /dev/null
  echo "Enviado: $device temp=$TEMP"
done

# Simular consumer Lambda (alertas) — lee shard 0
SHARD=$(aws kinesis list-shards \
  --stream-name iot-sensors \
  --region eu-west-1 \
  --query 'Shards[0].ShardId' \
  --output text)

ITER=$(aws kinesis get-shard-iterator \
  --stream-name iot-sensors \
  --shard-id "$SHARD" \
  --shard-iterator-type TRIM_HORIZON \
  --region eu-west-1 \
  --query 'ShardIterator' \
  --output text)

echo "=== Consumer Lambda (alertas) lee shard $SHARD ==="
aws kinesis get-records \
  --shard-iterator "$ITER" \
  --region eu-west-1 \
  | jq '.Records[] | {PartitionKey, Data: (.Data | @base64d | fromjson | {device, temp})}
        | select(.Data.temp > 30) | "ALERTA: \(.Data.device) = \(.Data.temp)°C"'

# El mismo shard sigue disponible para el consumer Firehose
# (lectura no destructiva — retención 24h)
echo "=== Los records siguen disponibles para otros consumers ==="
```

---

## Patrón 2: App logs → Firehose → S3 → Athena

**Caso:** Aplicación web genera logs de acceso (1 GB/día). Necesitas:
- Almacenar todos los logs sin gestionar servidores
- Queries ad-hoc sobre logs históricos
- Coste mínimo de almacenamiento

**Por qué Firehose:** Pipeline managed end-to-end. La app envía logs, Firehose los acumula y los deposita en S3 en prefijos por fecha. Athena los consulta directamente sin mover datos.

```
Aplicación web
(put-record directo a Firehose)
        │
        ▼  (buffer: 60s o 1MB)
Kinesis Firehose
        │  (prefijo: year=YYYY/month=MM/day=DD/)
        ▼
       S3
  year=2024/
    month=01/
      day=15/
        access-log-2024-01-15-10-00.gz
        access-log-2024-01-15-10-01.gz
        │
        ▼
      Athena
  (CREATE EXTERNAL TABLE → queries SQL)
```

**Comandos de prueba:**

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="lab01-kinesis-firehose-${ACCOUNT_ID}"

# Verificar que los archivos en S3 están particionados por fecha
aws s3 ls "s3://$BUCKET/data/" --recursive | head -20

# Ejemplo de tabla Athena sobre los datos de Firehose
# (requiere Athena configurada — esto es solo el DDL de referencia)
cat << 'ATHENA'
CREATE EXTERNAL TABLE app_logs (
  sensor  STRING,
  value   INT,
  ts      STRING
)
PARTITIONED BY (year STRING, month STRING, day STRING)
ROW FORMAT SERDE 'org.apache.hive.hcatalog.data.JsonSerDe'
STORED AS INPUTFORMAT 'org.apache.hadoop.mapred.TextInputFormat'
OUTPUTFORMAT 'org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat'
LOCATION 's3://lab01-kinesis-firehose-ACCOUNT_ID/data/'
TBLPROPERTIES ('has_encrypted_data'='false');

-- Query sobre los últimos 3 días
SELECT sensor, AVG(value) as avg_value, COUNT(*) as total
FROM app_logs
WHERE year = '2024' AND month = '01' AND day IN ('13','14','15')
GROUP BY sensor
ORDER BY avg_value DESC;
ATHENA

echo "Athena puede consultar directamente los archivos GZIP en S3 sin ETL previo."
```

**Comparación con alternativas:**

| Opción | Gestión | Coste | Latencia query |
|---|---|---|---|
| Firehose → S3 → Athena | Mínima | S3 + Athena por query | Segundos |
| KDS → Lambda → RDS | Alta | Lambda + RDS siempre encendido | Milisegundos |
| KDS → KDA → S3 | Media | KDA + S3 | Segundos |

Para logs históricos con queries esporádicas → **Firehose + S3 + Athena** es la opción más coste-efectiva.

---

## Patrón 3: KDS → Kinesis Data Analytics → detección anomalías

**Caso:** Stream de métricas de aplicación. Necesitas detectar cuando el error rate supera el 5% en los últimos 60 segundos.

**Por qué KDA:** SQL o Apache Flink directamente sobre el stream en tiempo real. No necesitas Lambda con lógica de ventanas deslizantes — KDA lo gestiona.

```
Métricas de app
(error_count, request_count por servicio)
        │
        ▼
Kinesis Data Streams
        │
        ▼
Kinesis Data Analytics (SQL)
  ┌─────────────────────────────────────┐
  │ CREATE OR REPLACE STREAM alerts AS  │
  │ SELECT service,                     │
  │        SUM(errors) / SUM(requests)  │
  │          AS error_rate              │
  │ FROM metrics_stream                 │
  │ WINDOW (RANGE INTERVAL '60' SECOND  │
  │         PRECEDING)                  │
  │ HAVING error_rate > 0.05            │
  └─────────────────────────────────────┘
        │
        ▼
  KDS Output Stream → Lambda → SNS → alerta PagerDuty
```

**Comandos de prueba (sin desplegar KDA — coste $0.11/KPU-hora):**

```bash
# Simular el stream de métricas
aws kinesis create-stream \
  --stream-name app-metrics \
  --shard-count 1 \
  --region eu-west-1

aws kinesis wait stream-exists \
  --stream-name app-metrics \
  --region eu-west-1

# Enviar métricas normales
for i in $(seq 1 5); do
  aws kinesis put-record \
    --stream-name app-metrics \
    --partition-key "api-gateway" \
    --data "$(echo -n "{\"service\":\"api-gateway\",\"requests\":100,\"errors\":2,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" | base64)" \
    --region eu-west-1 > /dev/null
done

# Enviar métrica anómala (error_rate = 20%)
aws kinesis put-record \
  --stream-name app-metrics \
  --partition-key "api-gateway" \
  --data "$(echo -n "{\"service\":\"api-gateway\",\"requests\":100,\"errors\":20,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" | base64)" \
  --region eu-west-1

# Simular detección manual (lo que KDA haría en tiempo real)
SHARD=$(aws kinesis list-shards --stream-name app-metrics --region eu-west-1 --query 'Shards[0].ShardId' --output text)
ITER=$(aws kinesis get-shard-iterator --stream-name app-metrics --shard-id "$SHARD" --shard-iterator-type TRIM_HORIZON --region eu-west-1 --query 'ShardIterator' --output text)

echo "=== Detección de anomalías (simulada) ==="
aws kinesis get-records --shard-iterator "$ITER" --region eu-west-1 \
  | jq '.Records[].Data | @base64d | fromjson
        | select((.errors / .requests) > 0.05)
        | "ANOMALIA: \(.service) error_rate=\((.errors / .requests * 100 | floor))%"'

# Limpiar
aws kinesis delete-stream --stream-name app-metrics --region eu-west-1
```

---

## Resumen de cuándo usar cada patrón

| Patrón | Componentes | Trigger para usarlo |
|---|---|---|
| IoT → KDS → múltiples consumers | KDS + Lambda + Firehose | Mismo evento lo procesan N sistemas distintos |
| Logs → Firehose → S3 → Athena | Firehose + S3 + Athena | Solo necesitas persistir y consultar historico |
| Métricas → KDS → KDA | KDS + KDA | Detección anomalías en ventanas de tiempo real |

**Anti-patrón frecuente:** Usar KDS cuando solo hay un consumer que escribe en S3. Firehose hace exactamente eso sin gestión de shards ni iterators.

---

## Limpieza

```bash
aws kinesis delete-stream --stream-name iot-sensors --region eu-west-1 2>/dev/null || true
aws kinesis delete-stream --stream-name app-metrics --region eu-west-1 2>/dev/null || true
```
