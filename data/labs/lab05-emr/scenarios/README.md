# Escenarios SAA-C03 — Amazon EMR

> 3 escenarios de examen: EMR vs alternativas, Spot instances, EMR + S3 como data lake.

---

## Escenario 1: EMR vs Glue vs Athena — tabla de decisión

**Pregunta:** Una empresa de medios tiene 3 necesidades distintas en su plataforma de datos:
1. Convertir 5 TB de logs diarios de CSV a Parquet, añadiendo columnas calculadas
2. Entrenar un modelo de recomendación con Spark MLlib sobre 2 TB de datos históricos
3. Un equipo de analistas ejecuta queries SQL ad-hoc sobre datos S3 10 veces al día

¿Qué servicio usar para cada necesidad?

**A)** Athena para todo
**B)** EMR para todo
**C)** Glue ETL para (1), EMR para (2), Athena para (3)
**D)** Glue ETL para (1) y (2), Athena para (3)

**Respuesta: C — Glue ETL, EMR, Athena respectivamente**

**Por qué:**

**Necesidad 1 — ETL CSV → Parquet (5 TB/día):**
- Glue ETL: serverless, sin cluster, procesa 5 TB con 10–20 workers G.2X en ~30 min.
- EMR: funciona, pero requiere gestionar el cluster. Sin ventaja real para este ETL estándar.
- **Glue ETL es la respuesta correcta** para "ETL serverless sin gestión de cluster".

**Necesidad 2 — ML con Spark MLlib (2 TB históricos):**
- Glue ETL: no soporta MLlib. Solo Spark para ETL, no ML.
- Athena: SQL analítico, no ML.
- **EMR** es la única opción — Spark MLlib requiere control del cluster, tuning de memoria, acceso a los modelos entrenados.

**Necesidad 3 — SQL ad-hoc 10 veces/día:**
- EMR: arrancar un cluster para 10 queries/día = sobreingeniería costosa.
- Glue ETL: no ejecuta SQL queries, transforma datos.
- **Athena** — serverless, paga $5/TB escaneado, ideal para uso esporádico.

---

## Escenario 2: EMR con Spot instances para Task nodes

**Pregunta:** Una empresa ejecuta un job Spark en EMR on EC2 que procesa 500 GB de datos históricos cada noche. El job tarda 3 horas. El arquitecto quiere reducir el coste al máximo. Los datos se leen y escriben en S3. ¿Qué configuración optimiza el coste?

**A)** Instancias On-Demand para todos los nodos (master, core, task)
**B)** Instancias Spot para todos los nodos (master, core, task)
**C)** Master + Core On-Demand, Task nodes en Spot
**D)** EMR Serverless (sin instancias EC2)

**Respuesta: C — Master + Core On-Demand, Task nodes en Spot**

**Por qué:**

```
Nodos EMR y su rol:
  Master:  coordina el job, YARN ResourceManager — NUNCA Spot (si muere, el job falla)
  Core:    procesamiento + almacenamiento HDFS — riesgo medio (si muere, pierdes datos HDFS)
  Task:    solo procesamiento, sin HDFS — Spot seguro (si se interrumpe, YARN reasigna)
```

- Master en Spot (B): si AWS reclama la instancia, el job entero falla sin posibilidad de recuperación. Nunca Spot para master.
- Todos On-Demand (A): funciona, pero el coste es máximo.
- Task nodes en Spot (C): ahorro de hasta 70–90% en los workers más numerosos. Si se interrumpe un Task node, YARN reasigna el trabajo a otros nodes. Como los datos están en S3 (no HDFS), no hay riesgo de pérdida de datos.
- EMR Serverless (D): válido y más simple, pero el enunciado especifica EMR on EC2 con control de Spot.

**Regla del examen:** "Reducir coste EMR on EC2" + "datos en S3 (no HDFS)" → **Task nodes en Spot**.

**Cuándo Core nodes también pueden ser Spot:**
- Si los datos están exclusivamente en S3 (no HDFS local)
- Si el job tiene checkpointing frecuente (Spark streaming)
- Con EMR Instance Fleets (múltiples tipos de instancia para reducir interrupciones)

---

## Escenario 3: EMR + S3 como data lake vs HDFS

**Pregunta:** Una empresa migra su cluster Hadoop on-prem a AWS. El arquitecto debate entre dos opciones:
- **Opción A:** EMR con HDFS — los datos se almacenan en los discos de los EC2 Core nodes
- **Opción B:** EMR con S3 — el cluster lee/escribe S3 directamente, HDFS solo para datos temporales

¿Cuál recomiendas y por qué?

**Respuesta: Opción B — EMR con S3 como data lake**

**Comparación:**

```
Opción A — EMR + HDFS:
  ✗ Datos se pierden si el cluster termina (por error o voluntariamente)
  ✗ No puedes escalar el storage independientemente del compute
  ✗ Si reduces el cluster (scale-in), pierdes bloques HDFS de los nodes eliminados
  ✗ No puedes compartir datos entre distintos clusters EMR
  ✓ Menor latencia I/O (discos locales vs S3)
  ✓ Compatible con workloads que requieren escritura incremental en HDFS

Opción B — EMR + S3 (recomendado):
  ✓ Datos persistentes — el cluster puede terminarse y recrearse sin perder datos
  ✓ Escala storage y compute independientemente (S3 es ilimitado)
  ✓ Múltiples clusters pueden leer los mismos datos en S3
  ✓ Integración nativa con Glue Catalog, Athena, Firehose, etc.
  ✓ Modelo de data lake — datos siempre disponibles para cualquier servicio AWS
  ✗ Latencia de S3 mayor que HDFS local (mitigable con EMRFS y S3A connector)
```

**Patrón arquitectónico recomendado:**
```
EMR Cluster
  └── lee de S3 (cold data)
  └── shuffle en HDFS local (temporal, inter-stage)
  └── escribe resultados en S3
  └── cuando termina → S3 tiene todos los datos, cluster puede eliminarse
```

**Regla del examen:** "Migración Hadoop a AWS" + "mantener datos accesibles tras terminar el cluster" → **EMR + S3 (no HDFS)**. S3 con EMRFS es el equivalente de HDFS en AWS moderno.

---

## Tabla de decisión: EMR vs Glue vs Athena

| Criterio | EMR | Glue ETL | Athena |
|---|---|---|---|
| **Tipo de carga** | Batch complejo, ML, streaming | ETL batch serverless | SQL ad-hoc |
| **Frameworks** | Spark, Hive, Presto, HBase, Flink | Solo Spark | SQL estándar |
| **Gestión cluster** | Alta (on EC2) / Baja (Serverless) | Ninguna | Ninguna |
| **ML** | Sí (Spark MLlib, TensorFlow) | No | No |
| **Expertise requerido** | Spark/Hadoop | Spark básico | SQL |
| **Arranque** | 5–10 min (on EC2) / 1–3 min (Serverless) | Segundos | Segundos |
| **Coste modelo** | EC2/hora × nodos o vCPU-hora job | DPU-hora de job | $5/TB escaneado |
| **Spot support** | Sí (on EC2 Task nodes) | No (serverless) | No (serverless) |
| **Cuándo** | Control total, PBs, ML, Hive/Presto | ETL sin expertise, serverless | Exploración, queries ocasionales |

**Resumen en una frase por servicio:**
- **EMR:** cuando necesitas el martillo grande — control total de Spark, ML, frameworks no-Spark
- **Glue ETL:** cuando quieres ETL sin gestionar nada — serverless, simple, suficiente para la mayoría
- **Athena:** cuando solo quieres hacer preguntas — SQL sobre datos S3 sin mover ni transformar nada
