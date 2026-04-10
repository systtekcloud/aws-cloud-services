# Consistencia eventual en CQRS: qué aceptar y qué no

## El problema de "read-your-writes"

Escenario problemático:
```
1. Usuario actualiza su dirección de envío (Command → DynamoDB)
2. DynamoDB Streams → Lambda → ElastiCache (500ms después)
3. Usuario hace GET /perfil (Query → ElastiCache)
4. ElastiCache devuelve la dirección ANTIGUA (todavía no propagada)
```

El usuario acaba de cambiar su dirección y ve la antigua. Esto genera desconfianza.

### Solución: sticky reads para operaciones críticas

```python
# Command handler — al actualizar, marca la versión
def actualizar_direccion(usuario_id, nueva_direccion):
    response = dynamodb.update_item(
        Key={'usuario_id': {'S': usuario_id}},
        UpdateExpression='SET direccion = :d, version = version + :v',
        ExpressionAttributeValues={
            ':d': {'S': nueva_direccion},
            ':v': {'N': '1'}
        },
        ReturnValues='UPDATED_NEW'
    )
    nueva_version = response['Attributes']['version']['N']

    # Guardar versión en sesión del usuario (cookie/JWT claim)
    return {'version': nueva_version}

# Query handler — si el usuario tiene versión en sesión, va a DynamoDB directamente
def obtener_perfil(usuario_id, version_requerida=None):
    if version_requerida:
        # Read-your-writes: ir directamente a DynamoDB (fuente de verdad)
        return dynamodb.get_item(Key={'usuario_id': {'S': usuario_id}})
    else:
        # Cache OK para usuarios que no acaban de escribir
        cached = redis.get(f'perfil:{usuario_id}')
        if cached:
            return json.loads(cached)
        return dynamodb.get_item(Key={'usuario_id': {'S': usuario_id}})
```

---

## Qué consistencia eventual es aceptable

| Operación | Aceptable | Por qué |
|-----------|-----------|---------|
| Actualizar dirección | NO | El usuario espera ver el cambio inmediatamente |
| Añadir al carrito | NO | El usuario acaba de añadir algo, quiere verlo |
| Cambiar precio de producto (admin) | SÍ | El admin no está mirando el catálogo al mismo tiempo |
| Actualizar descripción (admin) | SÍ | Sin urgencia |
| Stock disponible en catálogo | SÍ con caveats | Puede mostrar "disponible" aunque queden pocas unidades |
| Stock en checkout | NO | Si dice "en stock", tiene que estarlo al confirmar |
| Rating/reviews | SÍ | 500ms de lag en rating es imperceptible |

---

## Cache invalidation: las dos maneras

### Manera 1: Event-driven (preferida)

```python
# Lambda Projector (desde DynamoDB Streams)
def handler(event, context):
    for record in event['Records']:
        if record['eventName'] in ['INSERT', 'MODIFY']:
            nuevo = record['dynamodb']['NewImage']
            producto_id = nuevo['producto_id']['S']

            # Actualizar OpenSearch
            es_client.index(
                index='productos',
                id=producto_id,
                body=deserialize(nuevo)
            )

            # Invalidar cache (no actualizar — dejar que expire o que el próximo query lo rellene)
            redis.delete(f'producto:{producto_id}')
            redis.delete(f'categoria:{nuevo["categoria"]["S"]}:listado')
```

**Por qué invalidar y no actualizar:** actualizar la cache desde el projector requiere conocer el formato exacto del cache. Si la cache contiene datos de múltiples fuentes (producto + reviews + stock), el projector tendría que conocer toda esa lógica. Es más limpio invalidar y dejar que el query handler reconstruya la cache en el siguiente acceso.

### Manera 2: TTL-based (más simple, menos fresco)

```python
# Cada item en cache tiene TTL de 60 segundos
redis.setex(f'producto:{producto_id}', 60, json.dumps(producto))

# Después de 60s, el siguiente GET va a DynamoDB y recarga
```

Adecuado para: datos que cambian poco (catálogos de categorías, configuración).  
No adecuado para: stock en tiempo real, precios dinámicos.

---

## Reindexación completa (cuando algo va mal)

Si el projector falla durante 1 hora y OpenSearch queda desactualizado:

```bash
# 1. Leer todos los items de DynamoDB y reindexar en OpenSearch
# DynamoDB Scan + bulk index en OpenSearch

aws lambda invoke \
  --function-name cqrs-reindex \
  --payload '{"desde": "2026-04-10T00:00:00Z", "hasta": "2026-04-10T01:00:00Z"}' \
  response.json

# 2. El reindexador usa DynamoDB Streams export o un Scan completo con filtro por ts_modificado
```

**Por eso el campo `ts_modificado` es crítico:** sin él, no se puede hacer reindexación parcial.

---

## DynamoDB como fuente de verdad

Aunque los reads van a OpenSearch/ElastiCache, DynamoDB siempre tiene la versión canónica. Si hay discrepancia:

1. Lo que está en DynamoDB es correcto
2. Los read stores son proyecciones que se reconstruyen desde DynamoDB
3. Nunca escribir directamente en OpenSearch o ElastiCache sin pasar por DynamoDB primero
