# Escenarios SAA-C03 — Amazon OpenSearch

> 3 escenarios: OpenSearch vs CloudWatch, pipeline Firehose → OpenSearch, búsqueda en app vs RDS.

---

## Escenario 1: OpenSearch vs CloudWatch Logs Insights para log analytics

**Pregunta:** Una empresa de SaaS tiene sus microservicios en ECS Fargate. Los logs van a CloudWatch Logs automáticamente. El equipo de operaciones quiere:
- Dashboard en tiempo real con errores/hora, latencia p99 por servicio, top endpoints
- Alertas cuando el error rate supera el 5%
- Búsqueda de logs por mensaje de error completo (ej: buscar todos los logs con "connection refused")

El equipo valora la simplicidad y quiere mínima infraestructura adicional.

¿Qué solución usar?

**A)** OpenSearch Service con pipeline Firehose → OpenSearch
**B)** CloudWatch Logs Insights + CloudWatch Dashboards + CloudWatch Alarms
**C)** Athena con acceso a S3 (exportar logs de CW a S3)
**D)** Redshift con tabla de logs cargada via Firehose

**Respuesta: B — CloudWatch Logs Insights + Dashboards + Alarms**

**Por qué:**
- Los logs **ya están en CloudWatch** (ECS Fargate los envía automáticamente). No hay pipeline adicional que construir.
- CloudWatch Logs Insights soporta las queries pedidas: `filter @message like /connection refused/`, `stats avg(duration) by service`.
- CloudWatch Dashboards permite crear los widgets de errores/hora y latencia.
- CloudWatch Metric Filters + Alarms cubre el requisito de alertas cuando error rate > 5%.
- "Mínima infraestructura adicional" → OpenSearch requiere un dominio siempre encendido ($0.036/hora para t3.small), un pipeline Firehose, y gestión de índices.

**Cuándo la respuesta sería OpenSearch (A):**
- Los logs vienen de múltiples fuentes (on-prem, Kubernetes no-AWS, aplicaciones con logs no estándar)
- El equipo necesita dashboards más complejos (Kibana/OpenSearch Dashboards con mapas, correlaciones, drill-down)
- Requisito de búsqueda full-text avanzada con fuzzy matching, sinónimos, o scoring por relevancia
- Correlación entre logs, métricas, y trazas APM (Observability completo)

**Regla del examen:** "Logs de servicios AWS (ECS, Lambda, API GW, RDS)", "simplicidad", "mínima infraestructura" → **CloudWatch Logs Insights**. "Logs de aplicación propia", "búsqueda full-text compleja", "dashboards ricos y persistentes" → **OpenSearch**.

---

## Escenario 2: Pipeline Firehose → OpenSearch completo

**Pregunta:** Una plataforma de e-commerce procesa millones de eventos de click-stream (búsquedas, páginas vistas, añadir al carrito). El equipo quiere:
- Indexar todos los eventos en < 2 segundos después de ocurrir
- Dashboards de comportamiento de usuarios en tiempo real
- Búsqueda de patrones: "¿qué usuarios buscaron 'zapatillas' y no compraron?"
- Retención de datos de 30 días en OpenSearch, después mover a S3

¿Cuál es la arquitectura correcta?

**A)** App → Kinesis Data Streams → Lambda → OpenSearch REST API (INSERT directo)
**B)** App → Kinesis Data Streams → Firehose (destino OpenSearch) con buffer 60s
**C)** App → SQS → Lambda → OpenSearch REST API
**D)** App → Kinesis Data Streams → Lambda → RDS → dashboards Tableau

**Respuesta: B — KDS → Firehose → OpenSearch**

**Por qué:**

```
Opción A (Lambda → OpenSearch directo):
  Problema: 1 invocación Lambda por evento = N conexiones HTTP a OpenSearch
  A millones de eventos/día → miles de conexiones simultáneas
  OpenSearch degrada bajo carga de escritura masiva en requests individuales
  Firehose batch es 10-100x más eficiente para indexación masiva

Opción B (Firehose → OpenSearch):
  ✓ Firehose buffer los eventos (60s o 1MB → lo que ocurra primero)
  ✓ Escribe en bulk a OpenSearch → mucho más eficiente
  ✓ Retry automático si OpenSearch está saturado
  ✓ Backup a S3 de documentos que fallan al indexar
  ✓ IndexRotationPeriod = "OneDay" → índices diarios para facilitar retención
  Latencia: ~60-120 segundos (near real-time, suficiente para dashboards)
```

**Para la retención de 30 días:** usar Index State Management (ISM) de OpenSearch para mover índices > 30 días a UltraWarm (S3-backed, más barato) y luego eliminarlos. Firehose con IndexRotation = OneDay crea índices por día, lo que facilita la eliminación.

**SQS → Lambda (C):** SQS no es un destino Firehose. Lambda → OpenSearch tiene el problema de escrituras individuales mencionado. Además SQS añade latencia innecesaria.

---

## Escenario 3: OpenSearch para búsqueda en aplicación vs RDS LIKE

**Pregunta:** Un marketplace tiene 5 millones de productos. Los usuarios buscan por texto libre ("auriculares bluetooth cancelación ruido menos 50 euros"). La búsqueda actual usa `SELECT * FROM products WHERE name LIKE '%bluetooth%' AND name LIKE '%auriculares%'`. Los tiempos de respuesta son de 3-5 segundos y los usuarios abandonan la búsqueda. ¿Cómo mejorar?

**A)** Añadir índice de texto completo en RDS (FULLTEXT INDEX en MySQL)
**B)** Migrar a Amazon OpenSearch para todas las búsquedas
**C)** Usar Amazon OpenSearch para búsqueda, mantener RDS para datos transaccionales
**D)** Usar Amazon Redshift con queries SQL de búsqueda

**Respuesta: C — OpenSearch para búsqueda, RDS para datos transaccionales**

**Por qué:**

```
Problema con RDS LIKE:
  "SELECT * WHERE name LIKE '%bluetooth%'"
  → full scan de 5M filas
  → no puede usar índices B-Tree con wildcard al inicio
  → lento, no escala, sin relevance scoring

RDS FULLTEXT INDEX (A):
  Mejor que LIKE, pero limitado:
  - Sin sinónimos, sin stemming (búsqueda → buscar)
  - Sin scoring por relevancia
  - No escala para millones de docs con alta concurrencia

OpenSearch para TODO (B):
  Problema: OpenSearch no es una base de datos ACID
  No deberías procesar pedidos, pagos, o inventario en OpenSearch
  Sin transacciones, sin foreign keys, sin consistencia fuerte

Patrón correcto (C):
  RDS → fuente de verdad (pedidos, pagos, inventario)
  OpenSearch → copia desnormalizada de datos de producto para búsqueda

  Sincronización:
  RDS → DMS (Database Migration Service) → OpenSearch
  o
  RDS → Lambda (trigger en cambios) → OpenSearch API
```

**Ventajas de OpenSearch para búsqueda:**
- Índice invertido: `"bluetooth auriculares"` → respuesta en < 100ms para 5M docs
- Relevance scoring: productos más relevantes primero (TF-IDF, BM25)
- Sinónimos: "auriculares" = "headphones" = "headset"
- Fuzzy matching: "bluetoth" → encuentra "bluetooth"
- Aggregaciones: faceted search (filtrar por marca, precio, rating)
- Sugerencias: autocomplete mientras escribes

**Regla del examen:** "Búsqueda full-text en aplicación", "usuarios buscan con texto libre", "lento con LIKE" → **OpenSearch**. Siempre en combinación con RDS para datos transaccionales — OpenSearch no reemplaza a RDS, lo complementa.

---

## Tabla de decisión: OpenSearch vs Athena vs Redshift vs CloudWatch

| Necesidad | Servicio | Razón |
|---|---|---|
| Búsqueda full-text en app (5M productos) | OpenSearch | Índice invertido, < 100ms |
| Logs analytics en tiempo real con dashboards | OpenSearch | Dashboards ricos, búsqueda en logs |
| Logs de servicios AWS (Lambda, ECS, RDS) | CloudWatch Logs Insights | Sin infraestructura, datos ya en CW |
| SQL ad-hoc sobre datos en S3 | Athena | Schema-on-read, $5/TB |
| Dashboard BI recurrente (Tableau, QuickSight) | Redshift | Rendimiento predecible, warehouse |
| Búsqueda geoespacial (near me, radio 10km) | OpenSearch | Geo queries nativas |
| Alertas basadas en patrones en logs | OpenSearch + Alerting | O CloudWatch Metric Filters si logs en CW |
| Analytics sobre eventos en tiempo real | OpenSearch o Redshift Serverless | Depende de si necesitas búsqueda o SQL |
