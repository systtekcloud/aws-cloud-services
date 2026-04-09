# Amazon OpenSearch Service — Mapa Conceptual

> **Módulo:** `data/labs/lab07-opensearch` | **Región:** eu-west-1
> ⚠️ **Coste:** Eliminar el dominio al terminar — cobra por hora aunque no haya datos.

---

## Qué es OpenSearch

**Amazon OpenSearch Service** (antes Elasticsearch Service) es un motor de búsqueda y analytics distribuido gestionado. Basado en Apache Lucene, usa un **índice invertido** — en lugar de almacenar filas como una base de datos, almacena para cada término qué documentos lo contienen. Esto hace que la búsqueda full-text sea extremadamente rápida.

```
RDS (índice B-Tree):
  Tabla: [id=1, msg="Error connecting to DB"], [id=2, msg="DB timeout"]
  Query: SELECT * WHERE msg LIKE '%DB%'  → full scan de todas las filas

OpenSearch (índice invertido):
  "error"     → [doc1]
  "connecting"→ [doc1]
  "db"        → [doc1, doc2]
  "timeout"   → [doc2]
  Query: search "DB" → consulta el índice → [doc1, doc2] en < 1ms
```

**Analogía DevOps:** OpenSearch ≈ **ELK Stack (Elasticsearch + Logstash + Kibana) gestionado en AWS**. Como MSK es RDS para Kafka, OpenSearch es el ELK Stack sin gestionar nodos, índices de réplica, o upgrades.

---

## Cuándo OpenSearch vs Athena vs Redshift

| | OpenSearch | Athena | Redshift |
|---|---|---|---|
| **Tipo de query** | Full-text search, logs analytics | SQL ad-hoc sobre S3 | SQL analítico predecible |
| **Datos** | Logs, eventos, semi-estructurados (JSON) | Cualquier formato en S3 | Estructurados en el warehouse |
| **Búsqueda** | Excelente (TF-IDF, BM25, fuzzy) | Limitada (LIKE/ILIKE) | Limitada |
| **Latencia** | Sub-segundo (índice invertido) | Segundos | Sub-segundo (warehouse) |
| **Visualización** | OpenSearch Dashboards (Kibana fork) | Sin dashboards nativo | QuickSight, Tableau |
| **Tiempo real** | Sí — indexación en < 1 seg | No — lee S3 on demand | Near real-time (batch load) |
| **Cuándo** | Logs de app, búsqueda en app, alertas ops | SQL ad-hoc data lake | BI dashboards recurrentes |

**Regla del examen:**
- "Full-text search", "búsqueda en aplicación", "logs analytics en tiempo real" → **OpenSearch**
- "SQL ad-hoc sobre S3" → **Athena**
- "Dashboard BI con queries SQL recurrentes" → **Redshift**
- "CloudWatch Logs Insights vs OpenSearch" → CloudWatch para logs AWS nativos (Lambda, EC2), OpenSearch para logs de aplicación con dashboards complejos

---

## Componentes clave

### Índice
Equivalente a una tabla en una base de datos relacional. Almacena documentos del mismo tipo (ej: índice `app-logs-2024-01`). OpenSearch permite índices con tiempo en el nombre para facilitar la rotación.

### Documento
Equivalente a una fila. Formato JSON. Cada documento tiene un `_id` único dentro del índice.

### Shard
Unidad de distribución. Un índice se divide en shards que se distribuyen entre nodos. Más shards = más paralelismo = más throughput. Menos shards = menos overhead.

### Réplica
Copia de un shard en otro nodo. Protege contra fallos de nodo y aumenta throughput de lectura.

### OpenSearch Dashboards
Interfaz web (fork de Kibana) para explorar datos, crear visualizaciones, y construir dashboards. Incluye:
- **Discover:** exploración interactiva de documentos
- **Visualize:** gráficos, mapas, métricas
- **Dashboard:** combinación de visualizaciones

---

## Patrones frecuentes en AWS

```
Patrón 1 — Log analytics (más común):
  App/Lambda → CloudWatch Logs
                     │
                     ▼ (Subscription Filter)
              Kinesis Firehose
                     │
                     ▼
              OpenSearch Service
                     │
                     ▼
          OpenSearch Dashboards
          (errores por hora, latencia, top endpoints)

Patrón 2 — Eventos en tiempo real:
  App → Kinesis Data Streams → Firehose → OpenSearch

Patrón 3 — Búsqueda en aplicación:
  Usuarios buscan "camiseta roja talla M"
  App → OpenSearch REST API → resultados en < 100ms
  (RDS LIKE query tomaría segundos para millones de productos)
```

---

## OpenSearch vs CloudWatch Logs Insights

| | CloudWatch Logs Insights | OpenSearch |
|---|---|---|
| **Origen de datos** | Solo logs en CloudWatch | Cualquier fuente via API/Firehose |
| **Búsqueda** | Queries propias (filter, stats, sort) | Lucene query syntax, DSL completo |
| **Dashboards** | CloudWatch Dashboards (limitados) | OpenSearch Dashboards (rico, Kibana-like) |
| **Retención** | Configurable (1 día–never) | Según política del índice |
| **Coste** | Incluido en CloudWatch ($0.005/GB ingestado) | Por nodo/hora + almacenamiento |
| **Correlación** | Solo logs CloudWatch | Logs + métricas + trazas (APM) |
| **Cuándo** | Logs AWS nativos (Lambda, API GW, ECS) rápido | Logs de aplicación, dashboards complejos, búsqueda |

**Regla del examen:** "Logs de servicios AWS, análisis rápido, sin infraestructura extra" → **CloudWatch Logs Insights**. "Dashboards operacionales complejos, logs de aplicación propia, búsqueda full-text" → **OpenSearch**.
