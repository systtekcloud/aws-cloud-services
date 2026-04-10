# Diseño: IoT Data Pipeline

## Flujo detallado

```
1. Sensores IoT
   - Protocolo: MQTT (port 8883, TLS) o HTTPS
   - Payload: { "device_id": "sensor-001", "temp": 87.3, "ts": 1712345678 }
   - Frecuencia: 1 mensaje cada 10 segundos por sensor
   - Volumen: 10K sensores × 6 msg/min = 60K msg/min = 1.000 msg/s

2. AWS IoT Core
   - Certificate-based authentication (X.509)
   - Topic: sensors/{device_id}/telemetry
   - Rules Engine evalúa CADA mensaje con SQL

   Rule 1 (todos los mensajes → Kinesis):
     SELECT * FROM 'sensors/+/telemetry'
     → Kinesis Data Streams (partition key = device_id)

   Rule 2 (alertas temperatura):
     SELECT device_id, temp, ts FROM 'sensors/+/telemetry'
     WHERE temp > 85
     → Lambda (alertas)

3. Lambda alertas
   - Invocación: sincrónica desde IoT Core Rule
   - Verifica cooldown: DynamoDB GetItem (última alerta por device_id)
   - Si cooldown > 5min: publica a SNS
   - SNS → email + SMS + PagerDuty webhook
   - Latencia total: IoT Core → Lambda → SNS ≈ 2-4 segundos

4. Kinesis Data Streams
   - Shards: 1 shard = 1 MB/s ingesta = ~1.000 msg/s
   - Con 10K sensores × 100 bytes/msg = 100 KB/s → 1 shard suficiente
   - Retención: 7 días (para replay si falla Lambda o Firehose)
   - PartitionKey = device_id → mismo shard para mismo sensor (ordering)

5. Lambda procesador (ESM de Kinesis)
   - BatchSize: 100 registros
   - BisectBatchOnFunctionError: true (binary search en fallos)
   - ParallelizationFactor: 1 (default, escala con shards)
   - Procesa cada batch:
     a. Escribe últimas lecturas en DynamoDB (upsert por device_id)
     b. Métricas custom a CloudWatch
     c. Transforma a Parquet y envía a Firehose

6. DynamoDB (lecturas en tiempo real)
   - PK: device_id
   - Campos: temp, ts_ultimo, status (normal/alerta/offline)
   - TTL: none (siempre se necesita el estado actual)
   - GSI: zone_id → todas las lecturas por zona industrial

7. Kinesis Data Firehose
   - Source: Lambda (PutRecord desde procesador) o directo desde Kinesis Streams
   - Destino: S3
   - Conversión: JSON → Apache Parquet (schema desde Glue Catalog)
   - Compresión: Snappy (equilibrio velocidad/compresión)
   - Buffer: 128MB o 300s (lo que ocurra primero)
   - Prefijo S3: sensors/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/

8. S3 (almacén histórico)
   - Lifecycle: S3 Standard (0-30 días) → S3-IA (30-90 días) → Glacier IR (90-730 días)
   - Particionamiento: por año/mes/día → Athena escanea solo la partición necesaria
   - Retención: 2 años (configurado en lifecycle rule)

9. AWS Glue Crawler
   - Ejecuta: diariamente a las 02:00 UTC
   - Detecta nuevas particiones automáticamente
   - Actualiza Data Catalog con schema Parquet

10. Amazon Athena
    - Queries ad-hoc sobre S3 sin servidor
    - Workgroup con $10/mes límite (protección contra queries caras)
    - Ejemplo: promedio de temperatura por zona en los últimos 30 días
```

## Schema de datos

```json
{
  "device_id": "sensor-zona-a-001",
  "zone_id": "zona-a",
  "plant_id": "planta-barcelona",
  "temp": 87.3,
  "pressure": 2.4,
  "humidity": 65,
  "ts": 1712345678,
  "firmware": "2.1.4"
}
```

## Decisiones de diseño

### ¿Por qué Kinesis y no SQS para el stream principal?

Con 10K sensores, múltiples sistemas necesitan consumir los mismos datos:
- Lambda procesador (DynamoDB + métricas)
- Kinesis Firehose (almacenamiento S3)
- (Futuro) ML pipeline para anomaly detection

SQS: un mensaje = un consumer. Para fan-out necesitarías SQS + SNS, añadiendo latencia y coste.

Kinesis: múltiples consumers del mismo stream, cada uno con su propio checkpoint. Firehose puede leer directamente del stream sin que Lambda lo procese primero.

### ¿Por qué Lambda y no Kinesis Analytics para alertas?

Kinesis Data Analytics (Apache Flink) es potente pero:
- Mínimo $0.11/KPU-hora × 24h × 30 días = ~$79/mes sin procesar nada
- Latencia: ventanas de 1-60 segundos
- Complejidad: hay que escribir SQL de streaming o Java/Python para Flink

Lambda directa desde IoT Core Rule:
- Coste: $0 si no hay alertas, $0.20/M invocaciones si las hay
- Latencia: 1-2 segundos
- Simplicidad: función Python de 30 líneas

Kinesis Analytics vale la pena con ventanas complejas (ej: "promedio móvil de 5 minutos") o correlación entre múltiples sensores.

### ¿Por qué S3 + Athena y no Redshift o InfluxDB?

- **InfluxDB/TimescaleDB:** excelente para time-series, pero requiere instancia siempre encendida (~$200/mes mínimo). Para queries ad-hoc esporádicas, Athena es más barato.
- **Redshift:** potente para queries complejas, pero $0.25/hora mínimo = $180/mes. Apropiado si hay equipos de analytics haciendo queries constantemente.
- **S3 + Athena:** $0 almacenamiento si datos pequeños, $5/TB escaneado en queries. Para 1GB/día de sensores, las queries mensuales costarían <$1.

### ¿Por qué Parquet + Snappy en Firehose?

```
JSON  raw:  1.000 msg × 150 bytes = 150 KB/s = 388 GB/mes
Parquet:    compresión ~10:1 → 38 GB/mes
Snappy:     adicional ~2:1 → 19 GB/mes

Ahorro S3: 388 GB × $0.023/GB = $8.92/mes  vs  19 GB × $0.023 = $0.44/mes
Ahorro Athena: queries escanean 19 GB en vez de 388 GB → 20× más barato y más rápido
```

## SLA y disponibilidad

```
IoT Core          99.9%
Kinesis           99.9%   (multi-AZ nativo)
Lambda            99.95%
DynamoDB          99.999%
S3                99.999999999% (durabilidad) / 99.99% (disponibilidad)
Firehose          99.9%

Punto crítico: Kinesis. Si cae, sensores acumulan en buffer local (si lo tienen)
o se pierden mensajes. Mitigación: retención 7 días en Kinesis para replay.
```
