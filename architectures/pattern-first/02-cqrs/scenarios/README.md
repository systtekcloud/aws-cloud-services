# Escenarios: CQRS

## Escenario 1: Reindexación completa de OpenSearch

**Cuándo:** el projector estuvo caído, OpenSearch tiene datos obsoletos, se añadió un campo nuevo al schema.

```python
# Lambda de reindexación (invocada manualmente o por cron)
import boto3, json

ddb      = boto3.client('dynamodb')
paginator = ddb.get_paginator('scan')

def handler(event, context):
    bulk_buffer = []

    for page in paginator.paginate(TableName='productos-prod'):
        for item in page['Items']:
            doc = deserialize(item)
            # Formato bulk de OpenSearch
            bulk_buffer.append(json.dumps({"index": {"_id": doc['producto_id']}}))
            bulk_buffer.append(json.dumps(doc))

            if len(bulk_buffer) >= 200:  # flush cada 100 docs
                send_bulk(bulk_buffer)
                bulk_buffer = []

    if bulk_buffer:
        send_bulk(bulk_buffer)
```

**Tiempo estimado:** 1M productos × 0.5KB = 500MB → DynamoDB Scan ~5min, reindexación ~10min.

Para volúmenes grandes: usar DynamoDB Export to S3 + S3 → OpenSearch via Firehose.

---

## Escenario 2: ¿Cuándo NO usar CQRS?

**CQRS añade complejidad. No usar cuando:**

1. **El dominio es simple:** si los mismos datos que escribes son los que lees (CRUD básico), CQRS es overkill.

2. **El equipo es pequeño (<5 personas):** gestionar dos modelos de datos, múltiples read stores y la sincronización requiere expertise.

3. **Consistencia fuerte es obligatoria:** en checkout (compra), el stock debe ser consistente. No puedes mostrar "en stock" en OpenSearch si DynamoDB ya vendió el último. Solución: el checkout lee **directamente de DynamoDB** (no del read store).

4. **El presupuesto no soporta OpenSearch + ElastiCache:** `t3.small.search` = $0.036/hora = $26/mes. `cache.t3.micro` Redis = $0.017/hora = $12/mes. Total mínimo: ~$38/mes solo en infraestructura de read stores.

---

## Escenario 3: CQRS sin OpenSearch (versión simplificada)

Para equipos que quieren los beneficios de CQRS sin el coste de OpenSearch:

```
DynamoDB (write) → DynamoDB Streams → Lambda → DynamoDB (read table)
```

**Read table optimizada para lectura:**
- Tabla separada con PK=categoria + SK=precio (para listados por categoría ordenados por precio)
- Tabla separada con PK=nombre (para búsqueda por nombre exacto)
- ElastiCache para los listados más accedidos

**Limitación:** sin full-text search. Solo búsqueda exacta o por prefijo.

**Ventaja:** sin OpenSearch → $26/mes menos, sin VPC requerida.

---

## Escenario 4: Event Sourcing + CQRS

**Extensión natural:** en vez de guardar el estado actual en DynamoDB, guardar todos los eventos.

```
POST /productos → Lambda → DynamoDB Events table
  PK = producto_id
  SK = timestamp
  evento = "ProductoCreado" | "PrecioActualizado" | "StockModificado"
  payload = {...}

Lambda Projector lee los eventos y construye el estado actual:
  eventos de producto_123 → estado_actual_de_producto_123

Read store (OpenSearch) = proyección de los eventos
Write store (DynamoDB) = log inmutable de eventos
```

**Beneficio:** historial completo de cambios (qué cambió, cuándo, por qué).  
**Coste:** más complejo de implementar, el estado actual requiere replay de eventos.

**Cuándo usar:** auditoría legal estricta, necesidad de time-travel queries ("¿cuál era el precio el 1 de enero?"), sistemas financieros.
