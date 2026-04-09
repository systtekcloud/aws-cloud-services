# Escenarios SAA-C03 — Amazon Redshift

> 4 escenarios: Redshift vs Athena, Spectrum, Firehose → Redshift, Multi-AZ HA.

---

## Escenario 1: Redshift vs Athena — cuál elegir

**Pregunta:** Una empresa de retail tiene:
- 5 TB de datos de ventas históricos en S3 (Parquet, particionados por fecha)
- Equipo de BI que ejecuta 200+ queries al día sobre dashboards de Tableau
- Los dashboards son siempre las mismas queries: revenue por región, tendencias semanales, top productos
- El equipo también hace análisis exploratorio ocasional con SQL directo

¿Qué arquitectura recomiendas?

**A)** Solo Athena para todo — menos gestión, datos ya en S3
**B)** Solo Redshift — cargar todo en el warehouse, máximo rendimiento
**C)** Redshift para los dashboards BI, Athena para el análisis exploratorio
**D)** Redshift Spectrum para todo — los datos se quedan en S3 pero se consultan desde Redshift

**Respuesta: C — Redshift para BI, Athena para exploración**

**Por qué:**

**Para los dashboards BI (200+ queries/día):**
- Las mismas queries ejecutadas 200 veces/día en Athena = 200 × (datos escaneados × $5/TB).
- Si cada query escanea 10 GB = $1/día de Athena. Parece poco, pero con 5 TB de tablas completas puede dispararse.
- Redshift Serverless: coste fijo por RPU-hora. Con 8 RPU y 8h activo al día = ~$23/día pero performance predecible.
- Tableau + Redshift = rendimiento óptimo. Tableau + Athena = latencia variable, problemas con concurrencia.

**Para el análisis exploratorio (ocasional):**
- Athena es ideal — sin infraestructura, pago por query, datos ya en S3.
- No tiene sentido cargar datos exploratorios en Redshift.

**Respuesta D (Spectrum):** Válida pero subóptima para 200 queries/día — Spectrum escanea S3 en cada query, sin el beneficio de datos pre-cargados y columnar optimizado.

**Regla del examen:** "Dashboards BI, queries recurrentes, Tableau/QuickSight, concurrencia alta" → **Redshift**. "SQL ad-hoc, exploración, datos en S3, uso esporádico" → **Athena**.

---

## Escenario 2: Redshift Spectrum para datos históricos

**Pregunta:** Una empresa financiera tiene:
- Datos de transacciones de los últimos 6 meses en Redshift (500 GB)
- Datos históricos de los últimos 5 años en S3 en formato Parquet (10 TB)
- Los analistas a veces necesitan queries que combinen datos recientes e históricos
- Mover 10 TB a Redshift costaría mucho en almacenamiento

¿Cómo permites que los analistas hagan queries combinadas sin duplicar datos?

**A)** Exportar regularmente datos de Redshift a S3 y usar Athena para queries históricas
**B)** Mover todos los datos históricos de S3 a Redshift
**C)** Configurar Redshift Spectrum con external schema apuntando a S3 vía Glue Catalog
**D)** Usar Glue ETL para unir los datasets antes de cada query

**Respuesta: C — Redshift Spectrum**

**Por qué:**
- Spectrum permite un único SQL que hace JOIN entre la tabla Redshift (6 meses, hot) y la tabla externa en S3 (5 años, cold) sin mover datos.
- Los analistas usan el mismo cliente Redshift, la misma sintaxis SQL — transparente.
- Mover 10 TB a Redshift (B): almacenamiento Redshift ≈ $0.024/GB/mes = $240/mes solo en storage. S3 = $0.023/GB/mes para 10 TB = $230/mes — similar, pero Redshift también cobra por compute.
- Exportar a S3 y usar Athena (A): requiere dos herramientas distintas, no puedes hacer JOINs directos.
- Glue ETL para unir antes de cada query (D): añade latencia y coste de procesamiento en cada query.

**Partition pruning en Spectrum:** Si la query filtra por `year='2022'`, Spectrum solo lee las particiones de 2022 en S3, no los 10 TB completos. Esto reduce el coste a solo los datos relevantes.

---

## Escenario 3: Firehose → Redshift para ingesta de streaming

**Pregunta:** Una plataforma de e-commerce quiere cargar eventos de click-stream en tiempo real a Redshift para análisis de comportamiento de usuarios. El volumen es 50.000 eventos/minuto. ¿Cuál es la arquitectura correcta?

**A)** Lambda con trigger KDS que hace INSERT en Redshift por cada evento
**B)** KDS → Firehose → Redshift (con COPY via S3 buffer)
**C)** KDS → Firehose → S3 → Glue ETL nightly → Redshift
**D)** Escribir directamente a Redshift desde la aplicación con JDBC

**Respuesta: B — KDS → Firehose → Redshift**

**Por qué:**

```
Anti-pattern (A y D):
  50.000 eventos/minuto = 833 INSERT/seg
  Redshift no está optimizado para INSERTs individuales → performance degrada
  Connection pool de Redshift se satura (máx ~500 conexiones)
  El nodo leader de Redshift se convierte en cuello de botella

Patrón correcto (B):
  KDS → Firehose (buffer 60s/1MB)
                 → escribe batch a S3 (trigger)
                 → ejecuta COPY a Redshift automáticamente
  
  COPY es hasta 1000x más eficiente que INSERTs individuales
  Firehose maneja el buffer, retry y el COPY — cero código
  Latencia: ~60-120 segundos (aceptable para analytics, no para alertas)
```

**Cuándo la opción C es correcta:** Si la latencia de 24h es aceptable y quieres controlar transformaciones complejas antes de cargar. Pero el enunciado dice "en tiempo real" → **Firehose**.

**Regla del examen:** "Cargar streaming a Redshift" → siempre **Firehose → Redshift** (COPY via S3). Nunca INSERT directo desde Lambda o aplicación para volúmenes altos.

---

## Escenario 4: Redshift Multi-AZ para alta disponibilidad

**Pregunta:** Una empresa está usando Redshift Provisioned para su plataforma de BI crítica. El equipo de negocio exige SLA de 99.99% uptime para los dashboards. ¿Qué configuración usar?

**A)** Redshift cluster single-AZ con snapshots automáticos cada hora
**B)** Redshift Multi-AZ con dos instancias activas (RA3 nodes)
**C)** Redshift Serverless (auto-gestiona la HA)
**D)** Dos clusters Redshift independientes con datos replicados via Glue

**Respuesta: B — Redshift Multi-AZ**

**Por qué:**
- Redshift Multi-AZ mantiene **dos instancias del cluster en diferentes AZs** con replicación síncrona. Failover automático en < 60 segundos sin pérdida de datos.
- Single-AZ con snapshots (A): los snapshots permiten recuperación de datos pero no son failover automático. Restaurar un snapshot tarda minutos u horas, no cumple 99.99% de uptime.
- Serverless (C): Redshift Serverless también tiene HA integrada, pero el enunciado especifica Provisioned para control preciso del rendimiento BI.
- Dos clusters independientes (D): posible pero muy complejo de mantener sincronizados, y doble coste sin el beneficio de failover automático.

**Coste adicional de Multi-AZ:** aproximadamente el doble del coste de compute (dos instancias activas). Vale la pena para sistemas críticos de BI con SLA alto.

**Redshift Serverless + HA:** Serverless también gestiona HA automáticamente (distribuido en múltiples AZs), sin configuración adicional. Para el examen: si el enunciado no especifica Provisioned → Serverless con HA automática es la respuesta más simple.

---

## Tabla de decisión completa: Redshift vs Athena vs OpenSearch

| Criterio | Redshift | Athena | OpenSearch |
|---|---|---|---|
| **Tipo de datos** | Estructurados, limpios | Cualquier formato en S3 | Logs, eventos, semi-estructurados |
| **Modelo** | Schema-on-write | Schema-on-read | Schema-flexible (inverted index) |
| **Queries** | SQL analítico complejo | SQL ad-hoc sobre S3 | Full-text search, agregaciones |
| **Concurrencia** | Alta (Concurrency Scaling) | Alta (serverless) | Alta |
| **Latencia** | Sub-segundo (datos en warehouse) | Segundos (lee S3) | Sub-segundo (índice invertido) |
| **Coste** | Fijo (cluster/RPU siempre encendido) | $5/TB escaneado | Por nodo/hora |
| **Herramientas BI** | Tableau, QuickSight, Power BI nativo | Limitado | Dashboards (OpenSearch Dashboards) |
| **Búsqueda full-text** | Limitada (LIKE, ILIKE) | Limitada | Excelente (TF-IDF, BM25) |
| **Caso principal** | Data warehouse BI | Data lake queries | Log analytics, búsqueda en app |

**Cuándo OpenSearch en lugar de Redshift o Athena:**
- Logs de aplicación con búsqueda por texto libre (stack traces, mensajes de error)
- Búsqueda en aplicación tipo "¿qué productos tienen X característica?"
- Dashboards operacionales en tiempo real (latencia < 1 seg)
- Datos semi-estructurados (JSON con campos variables)
