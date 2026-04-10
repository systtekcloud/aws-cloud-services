# CQRS — Command Query Responsibility Segregation

**Tipo:** Pattern-First  
**Patrón:** Separar las operaciones de escritura (Commands) de las de lectura (Queries) con modelos de datos optimizados para cada caso.

**Caso de uso:** Plataforma de e-commerce donde los writes van a DynamoDB (transaccional) y los reads desde múltiples read stores optimizados (OpenSearch para búsqueda, ElastiCache para listados frecuentes).

---

## El problema que resuelve

Un modelo de datos único intenta satisfacer dos objetivos opuestos:

**Escrituras necesitan:**
- Consistencia fuerte (el stock no puede ser negativo)
- Transacciones ACID (decrementar stock + crear pedido = atómico)
- Normalización (un producto en un lugar)

**Lecturas necesitan:**
- Velocidad (el catálogo debe cargar en <100ms)
- Flexibilidad (buscar por nombre, categoría, precio, rating)
- Escalabilidad (miles de consultas por segundo)

CQRS separa ambas responsabilidades con modelos distintos.

---

## Arquitectura

```
                    COMMAND SIDE (writes)
Cliente
  │ POST /productos, PUT /stock, POST /pedidos
  ▼
API Gateway → Lambda (Command Handler)
  │ Valida, aplica reglas de negocio
  ▼
DynamoDB (write store — source of truth)
  │
  ▼ DynamoDB Streams (change events)
Lambda (Projector)
  │ Actualiza read stores en función del evento
  ├────────────────────────────────────────────
  ▼                                            ▼
OpenSearch                               ElastiCache (Redis)
(búsqueda full-text,                     (listados frecuentes:
 faceted search,                          top productos, carrito,
 filtros complejos)                       sesiones de usuario)

                    QUERY SIDE (reads)
Cliente
  │ GET /productos/search?q=laptop
  │ GET /productos/categoria/electronica
  │ GET /carrito/{usuario_id}
  ▼
API Gateway → Lambda (Query Handler)
  │ Enruta al read store apropiado
  ├─ búsqueda → OpenSearch
  ├─ listado  → ElastiCache (si en cache) o DynamoDB (si miss)
  └─ detalle  → DynamoDB (consistency requerida)
```

---

## Por qué este patrón

**Un solo DynamoDB para todo:**
- Búsqueda full-text: DynamoDB no la soporta → necesitas Scan (caro) o ElasticSearch externo
- Filtros complejos: sin índice secundario adecuado, es ineficiente
- Latencia de listados: 20ms por GetItem es aceptable, pero para 100 productos en un listado son 2 segundos seriales

**CQRS con read stores:**
- OpenSearch: query `laptop AND precio<1000 AND rating>4` en <50ms
- ElastiCache: `GET carrito:user-123` en <1ms
- DynamoDB: sigue siendo la fuente de verdad para datos transaccionales

**Trade-off:** consistencia eventual entre write store y read stores. Si alguien actualiza el stock, OpenSearch lo refleja en ~500ms (tiempo de propagación via Streams → Lambda → OpenSearch).

---

## Módulos Terraform

| Módulo | Recursos | Descripción |
|--------|----------|-------------|
| [modules/command/](modules/command/) | Lambda command handlers + DynamoDB | Write side |
| [modules/projection/](modules/projection/) | Lambda projector + DynamoDB Streams | Sincronización |
| [modules/query/](modules/query/) | Lambda query handlers + OpenSearch + ElastiCache | Read side |

---

## Recursos relacionados

- [design/consistency.md](design/consistency.md) — Consistencia eventual: qué aceptar y qué no
- [scenarios/](scenarios/) — Read-your-writes, cache invalidation, reindexación completa
