# AWS Glue + Lake Formation — Mapa Conceptual

> **Módulo:** `data/labs/lab04-glue-lakeformation` | **Región:** eu-west-1

---

## AWS Glue — Tres componentes distintos

La confusión más frecuente en el examen: **Glue no es un único servicio** — son tres componentes con funciones completamente distintas.

```
AWS Glue
  ├── Glue Data Catalog    → metastore centralizado de schemas
  ├── Glue Crawlers        → descubren datos y crean entradas en el Catalog
  └── Glue ETL Jobs        → scripts Spark serverless para transformar datos
```

### Glue Data Catalog

Metastore centralizado. Almacena: bases de datos, tablas, schemas (columnas, tipos), particiones, y estadísticas. Es el **Hive Metastore de AWS** — todos los demás servicios lo usan como fuente de verdad.

```
Glue Data Catalog
      ▲         ▲         ▲         ▲
      │         │         │         │
   Athena     EMR    Redshift   Glue ETL
             (Spark)  Spectrum    Jobs
```

**Analogía DevOps:** Glue Catalog ≈ **schema registry** o un registro centralizado de tipos — como el Confluent Schema Registry para Kafka, pero para tablas de datos.

### Glue Crawlers

Agentes que escanean orígenes de datos (S3, RDS, DynamoDB, JDBC) e **infieren el schema automáticamente**, creando o actualizando tablas en el Catalog. No transforman datos — solo descubren su estructura.

```
S3 bucket (CSV, Parquet, JSON)
        │
        ▼
  Glue Crawler (ejecuta bajo demanda o en schedule)
        │
        ▼
  Glue Data Catalog
  (crea tabla con schema inferido, particiones detectadas)
```

Cuándo usar Crawlers vs definir schema manualmente:
- **Crawler:** datos que cambian de schema frecuentemente, múltiples formatos, datos particionados que crecen
- **Manual:** schema estable y conocido, control total sobre tipos

### Glue ETL Jobs

Scripts Spark (Python/Scala) que se ejecutan en workers serverless gestionados por AWS. Transforman datos: CSV → Parquet, normalización, joins, filtrado, aggregaciones.

```
S3 raw (CSV)
     │
     ▼
Glue ETL Job (Spark serverless)
     │  - filtra columnas PII
     │  - convierte a Parquet
     │  - particiona por fecha
     ▼
S3 processed (Parquet particionado)
```

**Analogía DevOps:** Glue ETL ≈ **job de CI/CD para datos** — se ejecuta, transforma, produce un artefacto (datos procesados) y termina.

---

## Lake Formation — Gobierno del data lake

Lake Formation es la **capa de seguridad y gobierno** por encima de Glue Catalog + S3. Centraliza el control de acceso para todos los servicios que consultan el data lake.

### Problema que resuelve

Sin Lake Formation, el acceso a datos en S3 se controla con bucket policies + IAM policies en cada servicio por separado. Es complejo y propenso a errores.

```
Sin Lake Formation:
  Usuario → Athena → S3 (necesita IAM policy para S3 + Athena)
  Usuario → EMR   → S3 (necesita IAM policy para S3 + EMR)
  Usuario → Glue  → S3 (necesita IAM policy para S3 + Glue)
  → Gestión duplicada, fácil cometer errores

Con Lake Formation:
  Usuario → Athena ─┐
  Usuario → EMR    ─┼─► Lake Formation (permisos centralizados) ─► S3
  Usuario → Glue   ─┘
  → Un único lugar donde defines quién ve qué
```

### Granularidad de permisos

Lake Formation permite control a nivel de:
- **Database:** acceso a toda la base de datos
- **Table:** acceso a una tabla específica
- **Column:** acceso solo a ciertas columnas (útil para datos PII)
- **Row:** filtros de fila (row-level security) para multi-tenant

**Analogía DevOps:** Lake Formation ≈ **RBAC para el data lake** — como los roles de Kubernetes RBAC pero para datos analíticos.

---

## Lake Formation vs S3 Bucket Policies

| | Lake Formation | S3 Bucket Policies |
|---|---|---|
| **Granularidad** | Table, Column, Row | Bucket, Prefix (objeto) |
| **Integración** | Athena, EMR, Glue, Redshift Spectrum | Cualquier acceso a S3 |
| **Auditoría** | CloudTrail con detalle de tabla/columna accedida | CloudTrail nivel de objeto S3 |
| **Gestión** | Centralizada — un punto de control | Distribuida — policy por bucket |
| **Cuándo usar** | Data lake con múltiples servicios y usuarios | Acceso directo a S3, sin servicios analíticos |

---

## Glue vs EMR para ETL

| | Glue ETL | EMR |
|---|---|---|
| **Gestión** | Serverless — sin cluster que gestionar | Cluster propio (EC2 o EKS) |
| **Coste** | Por DPU-hora de job | Por EC2-hora siempre (cluster encendido) |
| **Control** | Bajo — AWS gestiona Spark | Alto — configuración completa de Spark |
| **Frameworks** | Solo Spark (Python/Scala) | Spark, Hive, Presto, HBase, Flink, Hudi |
| **Volumen** | Suficiente para mayoría de ETL | Necesario para PBs o tuning muy fino |
| **Cuándo** | ETL simples o moderados sin expertise Spark | Cargas complejas, equipos Spark expertos, ML con Spark MLlib |

**Regla del examen:** "ETL serverless sin gestionar cluster" → **Glue**. "Procesamiento Spark a escala con control total" → **EMR**.

---

## Athena vs Redshift

| | Athena | Redshift |
|---|---|---|
| **Modelo** | Schema-on-read | Schema-on-write |
| **Datos** | Raw en S3 (CSV, Parquet, JSON, ORC) | Cargados y estructurados en el warehouse |
| **Queries** | Ad-hoc, exploración, análisis ocasional | SQL predecibles y recurrentes (BI, dashboards) |
| **Coste** | $5/TB escaneado (sin infraestructura) | Fijo por cluster/RPU-hora |
| **Rendimiento** | Variable (depende del formato y particionado) | Alto y predecible para queries complejas |
| **Concurrencia** | Alta (serverless) | Alta con Concurrency Scaling |
| **Cuándo** | Data lake queries, exploración, pago por uso | BI tools, JOINs complejos, usuarios analíticos |

**Regla:** "SQL sobre datos en S3 sin mover datos" → **Athena**. "Dashboard BI con queries complejas recurrentes" → **Redshift**.
