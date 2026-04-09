# Lab 02 — Streaming Pipeline: KDS → Firehose → S3 raw/ en tiempo real

> **Objetivo:** Enviar eventos en streaming a Kinesis Data Streams, verlos llegar a S3 raw/ vía Firehose, y entender la latencia del pipeline near real-time.
> **Prerequisito:** Lab 01 desplegado (storage + ingestion activos).
> **Coste estimado:** <$0.50 (KDS cobra por shard-hora + PUT; Firehose cobra por GB procesado).

---

## Paso 1: Desplegar la capa de ingestion

```bash
cd data/labs/lab08-data-lake-terragrunt

# Solo ingestion (asume storage ya desplegado del lab 01)
cd dev/ingestion
terragrunt apply
```

Obtener el nombre del stream:

```bash
REGION="eu-west-1"

KDS_STREAM=$(terragrunt output -raw kinesis_stream_name --terragrunt-working-dir dev/ingestion 2>/dev/null \
            || echo "lab08-data-lake-dev-events")

BUCKET=$(terragrunt output -raw data_lake_bucket_id --terragrunt-working-dir dev/storage 2>/dev/null \
        || echo "lab08-data-lake-dev-data-lake")

echo "KDS Stream: $KDS_STREAM"
echo "Bucket:     $BUCKET"
```

---

## Paso 2: Enviar eventos individuales

```bash
# Enviar un evento de prueba (el --data acepta base64 o texto plano con --cli-binary-format)
aws kinesis put-record \
  --stream-name "$KDS_STREAM" \
  --data '{"event_id":"test-001","timestamp":"2024-03-15T12:00:00Z","user_id":"user-001","event_type":"page_view","payload":{"page":"/home"}}' \
  --partition-key "user-001" \
  --region "$REGION"
```

Respuesta esperada:
```json
{
  "ShardId": "shardId-000000000000",
  "SequenceNumber": "49648..."
}
```

---

## Paso 3: Enviar ráfaga de 20 eventos (simular tráfico real)

```bash
# Script que envía 20 eventos en 10 segundos
for i in $(seq 1 20); do
  EVENT_TYPE=$(echo "page_view add_to_cart search purchase" | tr ' ' '\n' | shuf -n1)
  USER_ID="user-$(( RANDOM % 100 + 1 ))"
  PRODUCT_ID="prod-$(( RANDOM % 50 + 1 ))"
  PRICE=$(echo "scale=2; $RANDOM / 100" | bc)
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  aws kinesis put-record \
    --stream-name "$KDS_STREAM" \
    --data "{\"event_id\":\"evt-${i}\",\"timestamp\":\"${TIMESTAMP}\",\"user_id\":\"${USER_ID}\",\"event_type\":\"${EVENT_TYPE}\",\"payload\":{\"product_id\":\"${PRODUCT_ID}\",\"price\":${PRICE}}}" \
    --partition-key "$USER_ID" \
    --region "$REGION" \
    --no-cli-pager > /dev/null

  echo "Enviado evento $i: $EVENT_TYPE para $USER_ID"
  sleep 0.5
done

echo ""
echo "20 eventos enviados. Firehose los escribirá en S3 en ~60 segundos."
```

---

## Paso 4: Verificar que llegan a S3

Firehose tiene un buffer de 60 segundos. Esperar 70-80 segundos:

```bash
echo "Esperando buffer de Firehose (60s)..."
sleep 70

# Listar objetos raw/ nuevos
echo "=== Objetos en raw/ ==="
aws s3 ls "s3://${BUCKET}/raw/" --recursive --region "$REGION" | tail -20

# Descargar y ver el contenido del último archivo
LATEST_KEY=$(aws s3api list-objects-v2 \
  --bucket "$BUCKET" \
  --prefix "raw/" \
  --query 'sort_by(Contents, &LastModified)[-1].Key' \
  --output text \
  --region "$REGION")

echo ""
echo "Último archivo: $LATEST_KEY"
aws s3 cp "s3://${BUCKET}/${LATEST_KEY}" - --region "$REGION" | gunzip | head -10
```

> **Nota:** Los archivos están comprimidos con GZIP (configurado en el módulo Firehose). El `gunzip` los descomprime en el pipe.

---

## Paso 5: Leer directamente del KDS (consumer manual)

Mientras Firehose procesa en batch, podemos leer el stream directamente para latencia < 1s:

```bash
# Obtener el shard iterator (TRIM_HORIZON = desde el principio)
SHARD_ITERATOR=$(aws kinesis get-shard-iterator \
  --stream-name "$KDS_STREAM" \
  --shard-id "shardId-000000000000" \
  --shard-iterator-type TRIM_HORIZON \
  --region "$REGION" \
  --query 'ShardIterator' \
  --output text)

# Leer los primeros registros
aws kinesis get-records \
  --shard-iterator "$SHARD_ITERATOR" \
  --limit 5 \
  --region "$REGION" \
  --query 'Records[*].Data' \
  --output text | while read -r encoded; do
    echo "$encoded" | base64 -d
    echo ""
done
```

> **KDS vs Firehose:** leer del shard iterator da latencia < 100ms. Firehose da ~60-120s pero gestiona el sink S3 automáticamente. Para tiempo real usa Lambda como consumer del KDS; para bulk use Firehose.

---

## Paso 6: Observar métricas en CloudWatch

```bash
# Récords entrantes al KDS en los últimos 10 minutos
aws cloudwatch get-metric-statistics \
  --namespace "AWS/Kinesis" \
  --metric-name "IncomingRecords" \
  --dimensions "Name=StreamName,Value=${KDS_STREAM}" \
  --start-time "$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Sum \
  --region "$REGION" \
  --query 'Datapoints[*].{Time:Timestamp,Records:Sum}' \
  --output table

# Bytes entregados por Firehose a S3
aws cloudwatch get-metric-statistics \
  --namespace "AWS/Firehose" \
  --metric-name "DeliveryToS3.Bytes" \
  --dimensions "Name=DeliveryStreamName,Value=lab08-data-lake-dev-raw-delivery" \
  --start-time "$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Sum \
  --region "$REGION" \
  --query 'Datapoints[*].{Time:Timestamp,Bytes:Sum}' \
  --output table
```

---

## Paso 7: Entender la latencia end-to-end

```
Producer → KDS:          < 10 ms   (latencia de escritura al shard)
KDS → Firehose poll:     ~1 s      (Firehose lee del shard con polling)
Firehose buffer:         60 s      (espera hasta 60s O 1MB, lo primero)
Firehose → S3 write:     < 5 s     (PUT multipart a S3)
─────────────────────────────────────
Total end-to-end:        ~65-75 s  (near real-time, suficiente para batch analytics)
```

Para latencia < 1s: añadir un Lambda como consumer del KDS con trigger de tipo `kinesis`.

---

## Qué aprendiste

| Concepto | Detalle |
|---|---|
| KDS partition key | Determina el shard; misma key → mismos shard → orden garantizado |
| Firehose buffer | 60s o 1MB: Firehose no es real-time, es near real-time (batch micro) |
| Base64 en KDS | Los datos se codifican en base64 al leer; decodificar con `base64 -d` |
| Prefijos temporales | Firehose escribe en `raw/year=.../month=.../day=.../hour=...` automáticamente |
| GZIP en Firehose | `compression_format = "GZIP"` → S3 almacena comprimido; Athena lo lee sin descomprimir |
