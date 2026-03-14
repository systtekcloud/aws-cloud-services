# Fase 01 — DynamoDB: Modelado de Datos y Acceso

## Objetivo

Diseñar y crear una tabla DynamoDB con PK/SK compuesta para una tienda e-commerce, añadir un GSI para consultas inversas, y practicar los patrones de acceso fundamentales (Query vs Scan).

**Tiempo estimado:** 30-40 minutos
**Coste:** prácticamente 0€ (tabla vacía en On-Demand = ~0)

---

## Conceptos antes de empezar

```
┌───────────────────────────────────────────────────────────────────────┐
│  ESTRUCTURA DE UNA TABLA DYNAMODB                                      │
│                                                                        │
│  Partition Key (PK) ──── clave de distribución del hash               │
│  Sort Key (SK)      ──── clave de ordenación dentro de la partición   │
│                                                                        │
│  PK=CUSTOMER#1001  SK=ORDER#2024-01-15#001  →  {datos del pedido}     │
│  PK=CUSTOMER#1001  SK=ORDER#2024-01-20#002  →  {datos del pedido}     │
│  PK=CUSTOMER#1001  SK=PROFILE              →  {datos del cliente}     │
│                                                                        │
│  Query(PK=CUSTOMER#1001) → devuelve TODOS los ítems del cliente       │
│  Query(PK=CUSTOMER#1001, SK begins_with ORDER#) → solo pedidos        │
└───────────────────────────────────────────────────────────────────────┘
```

### Single-Table Design

DynamoDB favorece poner **múltiples entidades en una sola tabla** usando SK como discriminador de tipo. Esto evita JOINs (que no existen en DynamoDB) y optimiza el acceso a datos relacionados.

### Patrones de acceso a definir ANTES de diseñar la tabla

| ID | Patrón de acceso | PK | SK | Índice |
|----|------------------|----|----|--------|
| AP1 | Obtener todos los pedidos de un cliente | `CUSTOMER#<id>` | `ORDER#<fecha>#<id>` | Tabla principal |
| AP2 | Obtener datos de perfil de un cliente | `CUSTOMER#<id>` | `PROFILE` | Tabla principal |
| AP3 | Obtener pedido específico por ID | `ORDER#<id>` | — | GSI1 |
| AP4 | Listar pedidos pendientes de procesar | `STATUS#pending` | `ORDER#<fecha>#<id>` | GSI2 |

---

## Paso 1 — Crear la tabla principal

### Consola

1. **DynamoDB → Tables → Create table**
2. Table name: `ecommerce-orders`
3. Partition key: `PK` (String)
4. Sort key: `SK` (String)
5. **Table settings: Customize settings**

### Capacity

6. Capacity mode: **On-demand** (lab: sin capacidad predeterminada que pagar)
7. Table class: **DynamoDB Standard**

### Encryption

8. Encryption at rest: **Owned by Amazon DynamoDB** (por defecto, gratis para el lab)

9. **Create table**

<details>
<summary>CLI equivalente</summary>

```bash
aws dynamodb create-table \
  --table-name ecommerce-orders \
  --attribute-definitions \
    AttributeName=PK,AttributeType=S \
    AttributeName=SK,AttributeType=S \
  --key-schema \
    AttributeName=PK,KeyType=HASH \
    AttributeName=SK,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --tags Key=Project,Value=db-labs Key=Lab,Value=lab03 Key=Env,Value=lab \
  --region eu-west-1

# Esperar a que esté active
aws dynamodb wait table-exists \
  --table-name ecommerce-orders \
  --region eu-west-1

echo "Tabla creada"
```

</details>

---

## Paso 2 — Añadir GSI para consultas por ORDER#ID y STATUS

DynamoDB permite hasta 20 GSIs por tabla. Los GSIs se pueden crear **en cualquier momento** (a diferencia de los LSIs que solo se crean al crear la tabla).

### Consola

1. **DynamoDB → Tables → ecommerce-orders → Indexes tab**
2. **Create index**

#### GSI-1: Lookup por OrderID

| Campo | Valor |
|-------|-------|
| Partition key | `GSI1PK` (String) |
| Sort key | `GSI1SK` (String) |
| Index name | `GSI1` |
| Attribute projections | All |

3. **Create index**

#### GSI-2: Pedidos por Status + Fecha

4. **Create index** (segundo)

| Campo | Valor |
|-------|-------|
| Partition key | `GSI2PK` (String) |
| Sort key | `GSI2SK` (String) |
| Index name | `GSI2` |
| Attribute projections | All |

5. **Create index**

<details>
<summary>CLI equivalente</summary>

```bash
aws dynamodb update-table \
  --table-name ecommerce-orders \
  --attribute-definitions \
    AttributeName=PK,AttributeType=S \
    AttributeName=SK,AttributeType=S \
    AttributeName=GSI1PK,AttributeType=S \
    AttributeName=GSI1SK,AttributeType=S \
    AttributeName=GSI2PK,AttributeType=S \
    AttributeName=GSI2SK,AttributeType=S \
  --global-secondary-index-updates '[
    {
      "Create": {
        "IndexName": "GSI1",
        "KeySchema": [
          {"AttributeName": "GSI1PK", "KeyType": "HASH"},
          {"AttributeName": "GSI1SK", "KeyType": "RANGE"}
        ],
        "Projection": {"ProjectionType": "ALL"}
      }
    },
    {
      "Create": {
        "IndexName": "GSI2",
        "KeySchema": [
          {"AttributeName": "GSI2PK", "KeyType": "HASH"},
          {"AttributeName": "GSI2SK", "KeyType": "RANGE"}
        ],
        "Projection": {"ProjectionType": "ALL"}
      }
    }
  ]' \
  --region eu-west-1

# Esperar a que los índices estén activos (puede tardar 2-3 min)
echo "Esperando GSIs..."
aws dynamodb wait table-exists --table-name ecommerce-orders --region eu-west-1
# Verificar estado de los índices
aws dynamodb describe-table \
  --table-name ecommerce-orders \
  --query 'Table.GlobalSecondaryIndexes[*].{Name:IndexName,Status:IndexStatus}' \
  --output table --region eu-west-1
```

</details>

---

## Paso 3 — Insertar datos de ejemplo

### Consola (Explore Items → Create item)

O directamente con la CLI (más rápido para múltiples ítems):

```bash
# ---- Perfil de cliente ----
aws dynamodb put-item \
  --table-name ecommerce-orders \
  --item '{
    "PK": {"S": "CUSTOMER#1001"},
    "SK": {"S": "PROFILE"},
    "nombre": {"S": "Ana García"},
    "email": {"S": "ana@example.com"},
    "ciudad": {"S": "Madrid"},
    "tipo": {"S": "PROFILE"}
  }' \
  --region eu-west-1

# ---- Pedidos del cliente 1001 ----
aws dynamodb put-item \
  --table-name ecommerce-orders \
  --item '{
    "PK": {"S": "CUSTOMER#1001"},
    "SK": {"S": "ORDER#2024-01-10#ORD-001"},
    "GSI1PK": {"S": "ORDER#ORD-001"},
    "GSI1SK": {"S": "CUSTOMER#1001"},
    "GSI2PK": {"S": "STATUS#completed"},
    "GSI2SK": {"S": "2024-01-10#ORD-001"},
    "total": {"N": "89.99"},
    "estado": {"S": "completed"},
    "producto": {"S": "Libro AWS SAA-C03"},
    "tipo": {"S": "ORDER"}
  }' \
  --region eu-west-1

aws dynamodb put-item \
  --table-name ecommerce-orders \
  --item '{
    "PK": {"S": "CUSTOMER#1001"},
    "SK": {"S": "ORDER#2024-01-20#ORD-003"},
    "GSI1PK": {"S": "ORDER#ORD-003"},
    "GSI1SK": {"S": "CUSTOMER#1001"},
    "GSI2PK": {"S": "STATUS#pending"},
    "GSI2SK": {"S": "2024-01-20#ORD-003"},
    "total": {"N": "149.00"},
    "estado": {"S": "pending"},
    "producto": {"S": "Teclado mecánico"},
    "tipo": {"S": "ORDER"}
  }' \
  --region eu-west-1

# ---- Segundo cliente ----
aws dynamodb put-item \
  --table-name ecommerce-orders \
  --item '{
    "PK": {"S": "CUSTOMER#1002"},
    "SK": {"S": "PROFILE"},
    "nombre": {"S": "Carlos López"},
    "email": {"S": "carlos@example.com"},
    "ciudad": {"S": "Barcelona"},
    "tipo": {"S": "PROFILE"}
  }' \
  --region eu-west-1

aws dynamodb put-item \
  --table-name ecommerce-orders \
  --item '{
    "PK": {"S": "CUSTOMER#1002"},
    "SK": {"S": "ORDER#2024-01-18#ORD-002"},
    "GSI1PK": {"S": "ORDER#ORD-002"},
    "GSI1SK": {"S": "CUSTOMER#1002"},
    "GSI2PK": {"S": "STATUS#pending"},
    "GSI2SK": {"S": "2024-01-18#ORD-002"},
    "total": {"N": "259.99"},
    "estado": {"S": "pending"},
    "producto": {"S": "Monitor 27 pulgadas"},
    "tipo": {"S": "ORDER"}
  }' \
  --region eu-west-1
```

---

## Paso 4 — Practicar los patrones de acceso

### AP1: Todos los pedidos de un cliente (Query en tabla principal)

```bash
# Todos los ítems del cliente 1001
aws dynamodb query \
  --table-name ecommerce-orders \
  --key-condition-expression "PK = :pk" \
  --expression-attribute-values '{":pk": {"S": "CUSTOMER#1001"}}' \
  --region eu-west-1

# Solo los pedidos (SK begins_with ORDER#)
aws dynamodb query \
  --table-name ecommerce-orders \
  --key-condition-expression "PK = :pk AND begins_with(SK, :sk_prefix)" \
  --expression-attribute-values '{
    ":pk": {"S": "CUSTOMER#1001"},
    ":sk_prefix": {"S": "ORDER#"}
  }' \
  --region eu-west-1
```

### AP2: Perfil del cliente (Get Item exacto)

```bash
aws dynamodb get-item \
  --table-name ecommerce-orders \
  --key '{"PK": {"S": "CUSTOMER#1001"}, "SK": {"S": "PROFILE"}}' \
  --region eu-west-1
```

### AP3: Pedido específico por OrderID (Query en GSI1)

```bash
aws dynamodb query \
  --table-name ecommerce-orders \
  --index-name GSI1 \
  --key-condition-expression "GSI1PK = :pk" \
  --expression-attribute-values '{":pk": {"S": "ORDER#ORD-001"}}' \
  --region eu-west-1
```

### AP4: Todos los pedidos pendientes (Query en GSI2)

```bash
aws dynamodb query \
  --table-name ecommerce-orders \
  --index-name GSI2 \
  --key-condition-expression "GSI2PK = :status" \
  --expression-attribute-values '{":status": {"S": "STATUS#pending"}}' \
  --region eu-west-1
```

---

## Paso 5 — Comparar Query vs Scan (nunca usar Scan en producción)

```bash
# ✅ Query — eficiente, usa índice
aws dynamodb query \
  --table-name ecommerce-orders \
  --key-condition-expression "PK = :pk" \
  --expression-attribute-values '{":pk": {"S": "CUSTOMER#1001"}}' \
  --return-consumed-capacity TOTAL \
  --region eu-west-1
# ConsumedCapacity: ~0.5 RCU (solo lee los ítems del cliente)

# ❌ Scan — lee TODA la tabla (costoso y lento)
aws dynamodb scan \
  --table-name ecommerce-orders \
  --filter-expression "estado = :estado" \
  --expression-attribute-values '{":estado": {"S": "pending"}}' \
  --return-consumed-capacity TOTAL \
  --region eu-west-1
# ConsumedCapacity: lee TODOS los ítems aunque el filtro devuelva pocos
```

**Regla de oro para el examen:**
> Si la pregunta menciona "poor performance", "full table scan", "high read costs" → la solución es **rediseñar con GSI/LSI** para convertir el Scan en Query.

---

## ✅ Validaciones de la fase

```bash
# 1. Tabla activa
aws dynamodb describe-table \
  --table-name ecommerce-orders \
  --query 'Table.{Status:TableStatus,ItemCount:ItemCount,BillingMode:BillingModeSummary.BillingMode}' \
  --output table --region eu-west-1
# Status=ACTIVE, BillingMode=PAY_PER_REQUEST

# 2. GSIs activos
aws dynamodb describe-table \
  --table-name ecommerce-orders \
  --query 'Table.GlobalSecondaryIndexes[*].{Name:IndexName,Status:IndexStatus}' \
  --output table --region eu-west-1
# GSI1=ACTIVE, GSI2=ACTIVE

# 3. Items insertados
aws dynamodb scan \
  --table-name ecommerce-orders \
  --select COUNT \
  --region eu-west-1
# Count: 5
```
