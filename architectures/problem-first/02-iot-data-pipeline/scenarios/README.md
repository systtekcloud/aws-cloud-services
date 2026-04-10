# Escenarios y variantes

## Escenario 1: Anomaly Detection con ML

**Problema:** Los umbrales fijos (temp > 85°C) generan demasiados falsos positivos en verano. Se quiere detección de anomalías basada en patrones históricos.

**Solución: Amazon Lookout for Equipment o SageMaker**

```
Kinesis → Lambda → SageMaker endpoint (inference)
  │ envía batch de últimas N lecturas del sensor
  │
  ├─ Si anomaly_score > 0.9 → SNS alerta
  └─ Todos los scores → DynamoDB (historial de anomalías)
```

**Alternativa más simple:** Amazon Kinesis Data Analytics (Flink) con Random Cut Forest:
```sql
CREATE OR REPLACE STREAM "ANOMALY_STREAM" (
    device_id VARCHAR(32),
    temp       DOUBLE,
    anomaly_score DOUBLE
);

CREATE OR REPLACE PUMP "ANOMALY_PUMP" AS
    INSERT INTO "ANOMALY_STREAM"
    SELECT STREAM device_id, temp,
           RANDOM_CUT_FOREST(temp) OVER (
               PARTITION BY device_id
               ROWS 1000 PRECEDING
           ) AS anomaly_score
    FROM "SOURCE_SQL_STREAM_001"
    WHERE anomaly_score > 2.0;
```

---

## Escenario 2: Backfill histórico

**Problema:** El sistema estuvo caído 3 días. Los sensores tienen los datos en buffer local. ¿Cómo cargamos el histórico sin saturar el pipeline de tiempo real?

**Solución:**

```bash
# 1. Crear un Firehose de carga histórica separado
aws firehose create-delivery-stream \
  --delivery-stream-name sensors-backfill \
  --s3-destination-configuration ...

# 2. Script de backfill que envía a Firehose directamente (no a Kinesis)
# para no interferir con el pipeline de tiempo real
for file in /backfill-data/*.json; do
    aws firehose put-record-batch \
      --delivery-stream-name sensors-backfill \
      --records file://$file
done

# 3. Ejecutar Glue Crawler manualmente para registrar nuevas particiones
aws glue start-crawler --name sensors-prod
```

**Decisión clave:** enviar el backfill directamente a Firehose (no a Kinesis) evita que Lambda lo procese como tiempo real y dispare alertas falsas de temperatura antigua.

---

## Escenario 3: Multi-región (sensores en Europa y América)

**Problema:** Plantas en Frankfurt y Sao Paulo. La latencia MQTT desde Brasil a eu-west-1 añade 200ms.

**Arquitectura multi-región:**

```
Europa (sensores)     Frankfurt (eu-central-1)
                      └── IoT Core → Kinesis → Lambda → DynamoDB
                                                       ↘ Firehose → S3 eu

América (sensores)    Sao Paulo (sa-east-1)
                      └── IoT Core → Kinesis → Lambda → DynamoDB
                                                       ↘ Firehose → S3 sa

S3 Replication (CRR) ─────────────────────────────────────→ S3 central (us-east-1)
                                                              └── Athena (analytics global)
```

**DynamoDB Global Tables:** réplica automática entre regiones para el estado de sensores. El dashboard muestra datos de todos los sensores con latencia <1s.

---

## Escenario 4: Sensores con conectividad intermitente

**Problema:** Sensores en zonas sin cobertura constante. Se acumulan lecturas y las envían en batch cuando hay conexión.

**Solución con IoT Core + Greengrass:**

```
Sensor → Greengrass Core (gateway local)
  │ Buffer local hasta que hay red
  │
  ▼ (cuando hay conexión)
IoT Core → Kinesis (batch de mensajes)
```

**AWS IoT Greengrass:** ejecuta Lambda en el edge, buffer local, sincronización cuando hay conexión. El timestamp del mensaje es el del sensor (no del servidor), por eso el campo `ts` es crítico.

**En Athena:** particionamos por fecha de ingesta (`ingested_at`), no por timestamp del sensor. Para queries históricas se usa el campo `ts` en el WHERE:

```sql
SELECT device_id, AVG(temp), DATE_TRUNC('hour', from_unixtime(ts)) as hora
FROM iot_sensors_prod.telemetry
WHERE year = '2026' AND month = '04'  -- partition pruning
  AND ts BETWEEN 1712000000 AND 1712086400  -- filtro temporal real
GROUP BY 1, 3
ORDER BY 3;
```

---

## Anti-patrones a evitar

### Anti-patrón 1: Lambda directa desde IoT Core para todos los mensajes

```
IoT Core Rule → Lambda (1.000 msg/s) → DynamoDB + S3  ← MAL
```

**Por qué:** 1.000 invocaciones/segundo de Lambda = $1.44/día solo en invocaciones. Además, la escritura individual a S3 (1K objetos pequeños/s) es costosa e ineficiente para Athena.

**Corrección:** Kinesis agrupa mensajes → Lambda procesa batches de 100 → una sola escritura a Firehose que bufferea 128MB antes de escribir a S3.

### Anti-patrón 2: JSON en S3 sin Parquet

```
Firehose → S3 (JSON crudo, 388 GB/mes)  ← MAL
```

**Por qué:** Athena cobra $5/TB escaneado. Con 388 GB/mes en JSON, una query mensual completa cuesta $1.94. Con Parquet (20GB), la misma query cuesta $0.10 y es 20× más rápida porque solo lee las columnas necesarias.

### Anti-patrón 3: Thresholds estáticos para alertas

```
WHERE temp > 85  ← puede ser MAL dependiendo del sensor
```

**Por qué:** un sensor en el desierto tiene baseline diferente que uno en Escandinavia. El umbral debería ser relativo al histórico del sensor (percentil 99 de los últimos 30 días), no un valor global fijo.
