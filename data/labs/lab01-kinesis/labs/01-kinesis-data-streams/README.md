# Lab 01 — Kinesis Data Streams: crear, producir y consumir

> **Duración estimada:** 30 minutos | **Coste estimado:** < $0.05

---

## Objetivo

Crear un KDS con 2 shards, enviar records con distintas partition keys y consumirlos manualmente para entender el flujo completo: ShardIterator → GetRecords → SequenceNumber.

---

## Prerequisitos

```bash
aws sts get-caller-identity   # confirmar credenciales
aws --version                 # AWS CLI v2
jq --version                  # jq instalado
```

---

## Paso 1: Crear el stream

```bash
# Crear KDS con 2 shards
aws kinesis create-stream \
  --stream-name lab01-kds \
  --shard-count 2 \
  --region eu-west-1

# Esperar a que esté ACTIVE
aws kinesis wait stream-exists \
  --stream-name lab01-kds \
  --region eu-west-1

# Verificar
aws kinesis describe-stream-summary \
  --stream-name lab01-kds \
  --region eu-west-1 \
  --query 'StreamDescriptionSummary.{Status:StreamStatus,Shards:OpenShardCount,Retention:RetentionPeriodHours}'
```

Deberías ver `"Status": "ACTIVE"`, `"Shards": 2`, `"Retention": 24`.

---

## Paso 2: Enviar records

```bash
# Record 1 — PartitionKey: "sensor-001"
aws kinesis put-record \
  --stream-name lab01-kds \
  --partition-key "sensor-001" \
  --data "$(echo -n '{"device":"sensor-001","temp":22.5,"ts":"2024-01-15T10:00:00Z"}' | base64)" \
  --region eu-west-1

# Record 2 — PartitionKey: "sensor-002" (puede ir a shard diferente)
aws kinesis put-record \
  --stream-name lab01-kds \
  --partition-key "sensor-002" \
  --data "$(echo -n '{"device":"sensor-002","temp":19.8,"ts":"2024-01-15T10:00:01Z"}' | base64)" \
  --region eu-west-1

# Record 3 — misma PartitionKey que record 1 (mismo shard garantizado)
aws kinesis put-record \
  --stream-name lab01-kds \
  --partition-key "sensor-001" \
  --data "$(echo -n '{"device":"sensor-001","temp":23.1,"ts":"2024-01-15T10:00:02Z"}' | base64)" \
  --region eu-west-1
```

Observa en la respuesta: `ShardId` y `SequenceNumber`. Records con misma PartitionKey siempre van al mismo shard — el orden dentro del shard está garantizado.

---

## Paso 3: Obtener ShardIterator y leer records

```bash
# Obtener los shard IDs
SHARDS=$(aws kinesis list-shards \
  --stream-name lab01-kds \
  --region eu-west-1 \
  --query 'Shards[].ShardId' \
  --output text)

echo "Shards: $SHARDS"

# Leer el primer shard (TRIM_HORIZON = desde el principio)
SHARD_ID=$(echo $SHARDS | awk '{print $1}')

ITERATOR=$(aws kinesis get-shard-iterator \
  --stream-name lab01-kds \
  --shard-id "$SHARD_ID" \
  --shard-iterator-type TRIM_HORIZON \
  --region eu-west-1 \
  --query 'ShardIterator' \
  --output text)

# Leer records
aws kinesis get-records \
  --shard-iterator "$ITERATOR" \
  --limit 10 \
  --region eu-west-1 \
  | jq '.Records[] | {SequenceNumber, PartitionKey, Data: (.Data | @base64d)}'
```

Tipos de ShardIterator:
- `TRIM_HORIZON` — desde el primer record disponible (según retención)
- `LATEST` — solo records nuevos desde ahora
- `AT_SEQUENCE_NUMBER` — desde un SequenceNumber exacto
- `AFTER_SEQUENCE_NUMBER` — después de un SequenceNumber

---

## Paso 4: Verificar distribución entre shards

```bash
# Leer TODOS los shards
for SHARD_ID in $SHARDS; do
  echo "=== Leyendo shard: $SHARD_ID ==="
  ITERATOR=$(aws kinesis get-shard-iterator \
    --stream-name lab01-kds \
    --shard-id "$SHARD_ID" \
    --shard-iterator-type TRIM_HORIZON \
    --region eu-west-1 \
    --query 'ShardIterator' \
    --output text)

  RECORDS=$(aws kinesis get-records \
    --shard-iterator "$ITERATOR" \
    --limit 10 \
    --region eu-west-1)

  COUNT=$(echo "$RECORDS" | jq '.Records | length')
  echo "  Records en este shard: $COUNT"
  echo "$RECORDS" | jq '.Records[] | {PartitionKey, Data: (.Data | @base64d)}'
done
```

Observa: sensor-001 siempre está en el mismo shard. sensor-002 puede estar en el otro.

---

## Paso 5: Modificar retención

```bash
# Ver retención actual
aws kinesis describe-stream-summary \
  --stream-name lab01-kds \
  --region eu-west-1 \
  --query 'StreamDescriptionSummary.RetentionPeriodHours'

# Aumentar a 48 horas (Extended Data Retention — coste adicional)
aws kinesis increase-stream-retention-period \
  --stream-name lab01-kds \
  --retention-period-hours 48 \
  --region eu-west-1

# Volver a 24 horas (no aumentar en este lab — genera coste)
aws kinesis decrease-stream-retention-period \
  --stream-name lab01-kds \
  --retention-period-hours 24 \
  --region eu-west-1
```

**Impacto en coste:** Retención > 24h cuesta $0.023/shard-hora adicional. Con 2 shards y 7 días: 2 × 168h × $0.023 ≈ $7.73.

---

## Paso 6: Envío por lotes (PutRecords)

```bash
# PutRecords — hasta 500 records o 5MB por llamada
aws kinesis put-records \
  --stream-name lab01-kds \
  --records \
    "Data=$(echo -n '{"device":"sensor-003","temp":25.0}' | base64),PartitionKey=sensor-003" \
    "Data=$(echo -n '{"device":"sensor-004","temp":21.3}' | base64),PartitionKey=sensor-004" \
    "Data=$(echo -n '{"device":"sensor-001","temp":22.8}' | base64),PartitionKey=sensor-001" \
  --region eu-west-1 \
  | jq '{FailedRecordCount, Records: [.Records[] | {ShardId, SequenceNumber}]}'
```

Verifica `FailedRecordCount: 0`. En producción siempre reintenta los records fallidos.

---

## Validación rápida

```bash
./validate.sh
```

---

## Limpieza

```bash
aws kinesis delete-stream \
  --stream-name lab01-kds \
  --region eu-west-1
```

---

## Conceptos demostrados

| Concepto | Demostrado en |
|---|---|
| Shard como unidad de capacidad | Paso 1: 2 shards = 2 MB/seg entrada |
| PartitionKey determina shard | Paso 2 + 4: sensor-001 siempre mismo shard |
| ShardIterator para consumir | Paso 3: TRIM_HORIZON vs LATEST |
| SequenceNumber para orden | Paso 3: orden garantizado dentro del shard |
| Retención y coste | Paso 5: 24h default, coste extra >24h |
| PutRecords para batch | Paso 6: hasta 500 records por llamada |
