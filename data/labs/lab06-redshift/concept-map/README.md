# Amazon Redshift — Mapa Conceptual

> **Módulo:** `data/labs/lab06-redshift` | **Región:** eu-west-1
> ⚠️ **Coste:** Pausar o eliminar el workgroup al terminar — cobra por RPU/hora.

---

## Qué es Redshift

**Amazon Redshift** es un data warehouse SQL columnar a escala de PB. Está diseñado para queries analíticas complejas (GROUP BY, JOINs, agregaciones) sobre grandes volúmenes de datos estructurados. A diferencia de RDS (OLTP), Redshift está optimizado para OLAP — pocas escrituras, muchas lecturas analíticas.

```
OLTP (RDS/Aurora):          OLAP (Redshift):
  Muchas escrituras/seg       Pocas escrituras, grandes batches
  Rows individuales           Agregaciones sobre millones de filas
  Consistencia inmediata      Consistencia eventual aceptable
  3NF normalizado             Star/Snowflake schema desnormalizado
  Índices B-Tree              Almacenamiento columnar + compresión
```

**Almacenamiento columnar:**
```
Row-oriented (RDS):
  Fila 1: [id=1, name="Alice", dept="Eng", salary=90000]
  Fila 2: [id=2, name="Bob",   dept="HR",  salary=65000]
  → Para SUM(salary): lee TODAS las columnas de TODAS las filas

Columnar (Redshift):
  Columna salary: [90000, 65000, 78000, 88000, ...]
  → Para SUM(salary): lee SOLO la columna salary
  → 5–10x menos I/O, compresión por columna (valores similares juntos)
```

**Analogía DevOps:** Redshift ≈ **base de datos optimizada para lectura analítica** — como un RDS PostgreSQL pero con almacenamiento columnar, MPP (procesamiento masivamente paralelo), y optimizado para queries de BI en lugar de transacciones.

---

## Redshift vs Athena — Distinción CRÍTICA para el examen

| | Redshift | Athena |
|---|---|---|
| **Modelo** | Schema-on-write | Schema-on-read |
| **Datos** | Cargados y estructurados en el warehouse | Raw en S3 (CSV, Parquet, JSON, ORC) |
| **Queries** | Predecibles y recurrentes (dashboards, BI) | Ad-hoc, exploración, análisis ocasional |
| **Rendimiento** | Alto y predecible — datos optimizados | Variable (depende del formato y particionado) |
| **Concurrencia** | Alta, con Concurrency Scaling | Alta (serverless), pero cola de queries |
| **JOINs complejos** | Muy eficiente (MPP, datos co-localizados) | Menos eficiente (lee de S3 por columna) |
| **Coste modelo** | Fijo (cluster/RPU siempre encendido) | $5/TB escaneado (sin infraestructura) |
| **Mantenimiento** | Vacuum, analyze, distribución de tablas | Ninguno |
| **Cuándo** | BI tools, dashboards, 100+ queries/día | 10 queries/día, exploración, datos en S3 |

**Regla del examen:**
- "Dashboard BI con queries recurrentes, equipo de analistas, rendimiento predecible" → **Redshift**
- "SQL ad-hoc sobre datos S3, análisis ocasional, pago por uso" → **Athena**
- "Datos en S3 que no quieres mover pero también queries desde Redshift" → **Redshift Spectrum**

---

## Redshift Serverless vs Provisioned

| | Serverless | Provisioned |
|---|---|---|
| **Gestión** | Sin cluster — AWS escala automáticamente | Cluster EC2 propio (nodos y tipo) |
| **Coste** | Por RPU-hora mientras hay queries activas | Por nodo EC2 siempre (aunque sin queries) |
| **Arranque** | Segundos (warm) / 1-2 min (cold) | Siempre activo |
| **Control** | Bajo — configuras RPU mínimas/máximas | Alto — tipo de nodo, número, distribución |
| **Cuándo** | Labs, cargas variables, equipos pequeños | Producción con carga predecible y alta |
| **Para labs** | ✓ Ideal — sin coste fijo, auto-pause | ⚠️ Coste mínimo aunque no haya queries |

**Para este lab:** usamos **Redshift Serverless** con auto-pause.

---

## Redshift Spectrum

Extensión de Redshift que permite consultar datos **directamente en S3** desde Redshift, sin cargarlos en el warehouse. Usa el Glue Data Catalog como metastore.

```
Redshift Warehouse (datos hot — cargados, optimizados)
    +
Redshift Spectrum (datos cold — en S3, sin cargar)
    = Un único SQL que combina ambas fuentes

Ejemplo:
  SELECT r.customer_id, r.total_purchases, s.country
  FROM redshift_table r                    ← datos en Redshift
  JOIN external_schema.sales_history s    ← datos en S3 via Spectrum
  ON r.customer_id = s.customer_id
  WHERE s.year = '2023'
```

**Cuándo Spectrum vs mover datos a Redshift:**
- **Mover a Redshift:** datos que se consultan frecuentemente en JOINs complejos, alta concurrencia
- **Spectrum:** datos históricos (> 6 meses), acceso ocasional, volumen muy grande (PBs), datos que ya están en el data lake

---

## Arquitectura típica con Redshift

```
Streaming:
  KDS → Firehose → S3 (raw)
                     └── Glue ETL → S3 (processed/Parquet)
                                      └── Glue Catalog
                                            ├── Athena (ad-hoc)
                                            └── Redshift Spectrum (desde Redshift)

Batch:
  S3 (CSV/Parquet) → Redshift COPY command → Redshift tables
                                                └── BI tools (QuickSight, Tableau)
                                                └── SQL analítico recurrente

Gobierno:
  Lake Formation → permisos sobre Glue Catalog → controlados también en Spectrum
```

---

## Distribución de tablas — para el examen

Redshift distribuye las filas entre nodos (slices). La distribución afecta al rendimiento de JOINs:

| Estilo | Cuándo usar | Cómo funciona |
|---|---|---|
| `DISTSTYLE KEY` | Tablas grandes que se hacen JOIN frecuentemente | Filas con la misma clave van al mismo nodo |
| `DISTSTYLE ALL` | Tablas de dimensión pequeñas (< 3M filas) | Copia completa en cada nodo |
| `DISTSTYLE EVEN` | Sin patrón claro de JOIN | Round-robin entre nodos |
| `DISTSTYLE AUTO` | Dejar que Redshift decida | Redshift elige según el tamaño |

**Para labs con Redshift Serverless:** la distribución es menos crítica — el optimizador la gestiona automáticamente.
