# Troubleshooting 02 — DynamoDB: Query lento o Scan innecesario

## Escenario

Tu aplicación tarda demasiado en responder o los costes de DynamoDB son mucho mayores de lo esperado. En los logs:

```
Consumed 450.5 RCU for a query that returned only 3 items
```

O en CloudWatch: `ConsumedReadCapacityUnits` alta pero `ReturnedItemCount` baja → **está leyendo mucho para devolver poco**.

---

## Diagnóstico

### Paso 1: Identificar si usas Query o Scan

```bash
# Ver consumed capacity con --return-consumed-capacity
aws dynamodb scan \
  --table-name ecommerce-orders \
  --filter-expression "estado = :e" \
  --expression-attribute-values '{":e": {"S": "pending"}}' \
  --return-consumed-capacity TOTAL \
  --region eu-west-1

# Resultado problemático:
# "ConsumedCapacity": {"CapacityUnits": 2.5}
# Pero solo devolvió 2 ítems de 50 totales → leyó TODOS los ítems para filtrar
```

**Diferencia clave:**
- `Query` filtra en el storage (eficiente) — usa el índice
- `Scan` lee TODA la tabla y luego aplica el filtro en memoria (ineficiente)

### Paso 2: Medir el ratio de eficiencia

```bash
# Usar --return-consumed-capacity en tu Query/Scan y comparar:
# Items devueltos vs RCU consumidas

# Query eficiente: 1 RCU por 4KB leídos, solo lee los ítems del PK
# Scan ineficiente: lee TODA la tabla aunque tu filtro solo coincida con 1 ítem
```

### Paso 3: Ver el plan de acceso

```bash
# ¿Cuántos ítems tiene la tabla?
aws dynamodb scan \
  --table-name ecommerce-orders \
  --select COUNT \
  --region eu-west-1

# Si COUNT es grande (miles) y tu operación devuelve pocos ítems
# sin usar un índice, estás haciendo un Scan implícito
```

---

## Causas y soluciones

### Causa 1 — Usar `FilterExpression` sin `KeyConditionExpression` (Scan disfrazado)

```python
# ❌ MAL: Esto es un Scan con filtro — lee TODA la tabla
response = table.scan(
    FilterExpression=Attr('estado').eq('pending')
)

# ✅ BIEN: Usar GSI2 que tiene estado como PK
response = table.query(
    IndexName='GSI2',
    KeyConditionExpression=Key('GSI2PK').eq('STATUS#pending')
)
```

**La regla de oro:**
> Si necesitas filtrar por un atributo frecuentemente → ese atributo debería ser PK o SK de un GSI.

### Causa 2 — No existe el índice necesario para el patrón de acceso

**Identificar acceso patterns sin índice:**

```bash
# Ver si hay GSIs que cubran tu caso
aws dynamodb describe-table \
  --table-name ecommerce-orders \
  --query 'Table.GlobalSecondaryIndexes[*].{Name:IndexName,PK:KeySchema[0].AttributeName,SK:KeySchema[1].AttributeName}' \
  --output table --region eu-west-1
```

**Fix — Crear GSI para el patrón que falta:**

```bash
# Ejemplo: necesitas consultar por ciudad del cliente
aws dynamodb update-table \
  --table-name ecommerce-orders \
  --attribute-definitions \
    AttributeName=PK,AttributeType=S \
    AttributeName=SK,AttributeType=S \
    AttributeName=ciudad,AttributeType=S \
  --global-secondary-index-updates '[{
    "Create": {
      "IndexName": "GSI-ciudad",
      "KeySchema": [
        {"AttributeName": "ciudad", "KeyType": "HASH"},
        {"AttributeName": "SK", "KeyType": "RANGE"}
      ],
      "Projection": {"ProjectionType": "KEYS_ONLY"}
    }
  }]' \
  --region eu-west-1
```

### Causa 3 — Projection del GSI trae demasiados atributos

Si tu GSI tiene `ProjectionType=ALL` pero tu consulta solo necesita 2-3 atributos, estás pagando por leer datos innecesarios.

```bash
# Ver proyección actual de los GSIs
aws dynamodb describe-table \
  --table-name ecommerce-orders \
  --query 'Table.GlobalSecondaryIndexes[*].{Name:IndexName,Projection:Projection.ProjectionType}' \
  --output table --region eu-west-1
```

**Fix — Usar ProjectionType=KEYS_ONLY o INCLUDE para GSIs de alto tráfico:**

```python
# En Terraform/IaC, al crear el GSI:
global_secondary_index {
  name            = "GSI-ciudad"
  hash_key        = "ciudad"
  projection_type = "KEYS_ONLY"  # Solo PK+SK de la tabla base, no todos los atributos
}

# En la consulta, si solo necesitas las Keys para luego hacer GetItem:
response = table.query(
    IndexName='GSI-ciudad',
    KeyConditionExpression=Key('ciudad').eq('Madrid'),
    ProjectionExpression='PK, SK'  # Solo lo que necesitas
)
```

### Causa 4 — LSI vs GSI: elegir el índice equivocado

Un LSI (Local Secondary Index) **solo se puede crear al crear la tabla**. Tiene la misma Partition Key que la tabla base pero diferente Sort Key. Comparte la RCU/WCU con la tabla base.

```
LSI: misma PK, diferente SK — creación: solo al crear tabla
GSI: diferente PK y SK — creación: en cualquier momento
```

**Cuándo usar LSI:**
- Necesitas ordenar los ítems del mismo PK por un atributo diferente al SK
- Ejemplo: mismos pedidos de un cliente, ordenados por `total` en lugar de por fecha

**Error común:** intentar crear un LSI en una tabla existente → imposible.

**Fix:** recrear la tabla con LSI desde el inicio (en labs es fácil, en producción requiere migración de datos).

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|----------|-----------|
| ¿Cuándo usar Scan? | Casi nunca en producción. Solo en migraciones o tareas de backoffice. |
| ¿Solución a Scan frecuente? | Crear un GSI con el atributo de filtro como PK |
| ¿Diferencia entre LSI y GSI? | LSI: misma PK, solo al crear tabla. GSI: cualquier PK, en cualquier momento. |
| ¿Cuántos GSIs se pueden crear? | Hasta **20** por tabla |
| ¿Cuántos LSIs se pueden crear? | Hasta **5** por tabla |
| ¿GSI consume capacidad separada? | Sí, tiene su propio throughput (On-Demand: automático) |
