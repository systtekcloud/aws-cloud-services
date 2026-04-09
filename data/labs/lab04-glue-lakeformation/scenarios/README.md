# Escenarios SAA-C03 — Glue + Lake Formation

> 4 escenarios de examen con tablas de decisión.

---

## Escenario 1: Glue vs EMR para ETL

**Pregunta:** Una empresa tiene un pipeline ETL que procesa diariamente 50 GB de logs de aplicación en S3. El pipeline filtra registros inválidos, normaliza fechas, y convierte a Parquet. El equipo de datos no tiene expertise en Spark y quiere minimizar la gestión de infraestructura. ¿Qué servicio usar?

**A)** Amazon EMR con cluster Spark dedicado (instancias r5.xlarge)
**B)** AWS Glue ETL Jobs
**C)** AWS Lambda con trigger S3
**D)** Amazon Kinesis Data Analytics

**Respuesta: B — AWS Glue ETL Jobs**

**Por qué:**
- 50 GB/día es un volumen moderado. Glue lo maneja perfectamente con 2–4 workers G.1X.
- Glue ETL es serverless — sin cluster que gestionar, sin gestión de EC2, sin upgrades.
- El equipo no tiene expertise Spark. Glue tiene DynamicFrame API más simple que RDD/DataFrame puro + generación de código automática en Glue Studio.
- EMR (A): justificado si el equipo tiene expertise Spark y necesita tuning fino, o si el volumen es > TBs/día con lógica muy compleja. Aquí es overkill.
- Lambda (C): límite de 15 minutos y 10 GB de memoria. No apto para 50 GB de procesamiento.
- KDA (D): orientado a streams, no a batch sobre archivos S3.

**Cuándo EMR en lugar de Glue:**
- Volúmenes > 100 GB/hora con latencia crítica
- Necesitas Hive, Presto, HBase, o Flink (frameworks no disponibles en Glue)
- Tuning avanzado de Spark (spark.memory.fraction, executor sizing, etc.)
- ML con Spark MLlib
- El equipo ya tiene expertise Spark

---

## Escenario 2: Athena vs Redshift para analytics

**Pregunta:** Una startup de fintech tiene estas necesidades:
- Equipo de analistas que ejecuta 5–10 queries SQL por día para análisis exploratorio de fraude
- Datos almacenados en S3 en formato CSV y Parquet (3 TB totales, crecen 10 GB/día)
- Los analistas usan herramientas distintas (Python, SQL clients, Jupyter)
- El equipo quiere pagar lo mínimo posible sin infraestructura fija

¿Qué servicio usar?

**A)** Amazon Redshift Provisioned (dc2.large, 2 nodos)
**B)** Amazon Redshift Serverless
**C)** Amazon Athena
**D)** Amazon RDS PostgreSQL

**Respuesta: C — Amazon Athena**

**Por qué:**
- "Análisis exploratorio", "5–10 queries/día" → uso ad-hoc, no recurrente. Athena es ideal.
- Datos ya en S3 → Athena los consulta directamente sin mover ni cargar nada.
- "Pagar lo mínimo, sin infraestructura fija" → Athena cobra $5/TB escaneado. 10 queries × 100 MB = $0.005/día.
- Redshift Provisioned (A): cluster siempre encendido, ~$0.25/hora mínimo = $180/mes aunque no se use.
- Redshift Serverless (B): más flexible pero sigue siendo un warehouse con coste mínimo por RPU.
- RDS PostgreSQL (D): base de datos transaccional OLTP, no optimizado para analytics sobre S3.

**Cuándo Redshift en lugar de Athena:**
- Dashboards BI con queries complejas ejecutadas 100+ veces/día (el coste de Athena escala)
- JOINs entre múltiples tablas grandes donde la performance de Redshift supera a Athena
- Concurrencia alta de usuarios analíticos simultáneos
- Datos estructurados y limpios que benefician del schema-on-write

---

## Escenario 3: Lake Formation vs S3 Bucket Policies para gobierno

**Pregunta:** Una empresa de salud almacena datos de pacientes en un data lake en S3. Los datos son consultados por Athena (analistas), EMR (data engineers), y Glue (ETL). Los requisitos son:
- Los analistas pueden ver datos demográficos pero NO el historial médico (columnas PII)
- Los data engineers pueden ver todo
- El equipo de compliance necesita auditoría de qué columnas accede cada usuario

¿Qué mecanismo de control de acceso usar?

**A)** S3 bucket policies con prefijos separados por rol
**B)** IAM policies por usuario con acceso a S3
**C)** AWS Lake Formation con permisos a nivel de columna
**D)** Cifrado S3 con claves KMS distintas por dataset

**Respuesta: C — Lake Formation con permisos a nivel de columna**

**Por qué:**
- El requisito clave es **column-level security** (historial médico = columnas específicas). S3 no entiende columnas — solo objetos. No puedes bloquear una columna con bucket policy.
- Lake Formation permite `grant SELECT ON table (col1, col2) TO analyst` — exactamente lo que se pide.
- S3 bucket policies (A): solo granularidad de bucket/prefijo. Para columnas necesitarías una tabla diferente por set de columnas, lo cual es una arquitectura muy compleja de mantener.
- IAM policies (B): mismo problema — IAM controla acceso a servicios y buckets, no a columnas dentro de una tabla.
- KMS (D): protege datos en reposo, no controla qué columnas pueden leer los usuarios autenticados.
- **Auditoría:** Lake Formation registra en CloudTrail cada acceso con detalle de tabla, columna accedida, usuario, y timestamp. Ideal para compliance HIPAA/GDPR.

**Regla:** Cuando el enunciado menciona "column-level security", "row-level security", o "control de acceso granular en el data lake" → **Lake Formation**.

---

## Escenario 4: Arquitectura completa de data lake — Firehose vs Glue ETL hacia Redshift

**Pregunta:** Una empresa de retail quiere cargar datos de transacciones en tiempo real desde Kinesis Data Streams hacia Amazon Redshift para análisis BI. El volumen es 1.000 transacciones/segundo. ¿Cuál es la arquitectura más adecuada?

**A)** KDS → Lambda → Redshift (INSERT directo por cada transacción)
**B)** KDS → Firehose → Redshift (COPY command via S3)
**C)** KDS → Glue Streaming ETL → Redshift
**D)** KDS → Firehose → S3 → Glue ETL Job (batch nightly) → Redshift

**Respuesta: B — KDS → Firehose → Redshift**

**Por qué:**
- Redshift está diseñado para **cargas batch** (COPY command), no para INSERTs individuales. 1.000 INSERT/segundo degradaría drásticamente el rendimiento de Redshift.
- Firehose buffer los datos (60 seg o N MB), escribe a S3, y ejecuta `COPY` a Redshift automáticamente. Esto es exactamente para lo que está diseñado.
- Lambda con INSERT directo (A): anti-pattern. 1.000 conexiones/seg a Redshift = colapso del connection pool. Redshift tiene límite de ~500 conexiones simultáneas.
- Glue Streaming ETL (C): posible pero más complejo que Firehose para este caso simple.
- Glue ETL batch nightly (D): añade latencia de ~24h. Si el requisito es "tiempo real para BI", no es válido.

**Truco del examen:** "Cargar datos de streaming a Redshift" → casi siempre **Firehose → Redshift** (con buffer S3 intermedio). Firehose soporta nativamente Redshift como destino y ejecuta el COPY automáticamente.

---

## Tabla de decisión: Glue vs EMR vs Athena vs Redshift

| Necesidad | Servicio | Razón |
|---|---|---|
| ETL serverless sin gestionar cluster | Glue ETL | Sin infraestructura, pago por job |
| ETL con Spark a escala + tuning fino | EMR | Control total del cluster |
| SQL ad-hoc sobre S3 (exploración) | Athena | Schema-on-read, pago por TB escaneado |
| SQL analítico recurrente (dashboards BI) | Redshift | Performance predecible, schema-on-write |
| Descubrir schema de datos en S3 | Glue Crawler | Infiere tipos y particiones automáticamente |
| Metastore centralizado para múltiples servicios | Glue Catalog | Compartido por Athena, EMR, Redshift Spectrum |
| Column/row-level security en el data lake | Lake Formation | Único servicio con granularidad de columna |
| Cargar streaming a Redshift | Firehose → Redshift | Buffer + COPY automático |
| Queries sobre datos históricos en S3 desde Redshift | Redshift Spectrum | Federated query sin mover datos |
