# Amazon EMR — Mapa Conceptual

> **Módulo:** `data/labs/lab05-emr` | **Región:** eu-west-1
> ⚠️ **Coste:** Terminar el cluster/application inmediatamente tras el lab.

---

## Qué es EMR

**Amazon EMR (Elastic MapReduce)** es un cluster Hadoop/Spark gestionado. AWS aprovisiona y gestiona los nodos EC2, instala el framework, y configura el networking — pero tú controlas la configuración de Spark, el número de workers, y el tipo de instancia.

```
Tu código Spark/Hive/Presto
         │
         ▼
Amazon EMR (cluster gestionado)
  Master node  ─── coordina jobs
  Core nodes   ─── almacenamiento HDFS + procesamiento
  Task nodes   ─── solo procesamiento (ideales para Spot)
         │
         ▼
  Resultados en S3 (data lake) o HDFS (temporal)
```

**Analogía DevOps:** EMR ≈ **cluster Kubernetes pero para datos**. Como EKS te da Kubernetes sin gestionar el plano de control, EMR te da Spark/Hadoop sin gestionar ZooKeeper, YARN, ni el scheduler.

---

## EMR vs Glue ETL — Decisión clave

| | EMR | Glue ETL |
|---|---|---|
| **Gestión** | Tú gestionas el cluster (tipo EC2, tamaño, config) | Serverless — AWS gestiona todo |
| **Frameworks** | Spark, Hive, Presto, HBase, Flink, Hudi, Delta Lake | Solo Spark (Python/Scala) |
| **Control Spark** | Total — tuning de particiones, memoria, executor | Limitado — DPU abstrae la configuración |
| **Arranque cluster** | 5–10 minutos | Segundos (serverless) |
| **Coste** | EC2 por hora × nodos (core + task + master) | Por DPU-hora solo cuando el job corre |
| **Volumen típico** | TBs/PBs diarios | GBs/TBs, jobs moderados |
| **ML** | Spark MLlib, TensorFlow en cluster | No apto para ML |
| **Cuándo** | Expertise Spark, workloads complejos, PBs | ETL serverless simple, sin expertise Spark |

**Regla del examen:** "Sin gestionar cluster", "serverless ETL", "equipo sin Spark" → **Glue**. "Control total", "ML con Spark MLlib", "PBs", "Hive/Presto/HBase" → **EMR**.

---

## EMR Serverless vs EMR on EC2 vs EMR on EKS

| | EMR Serverless | EMR on EC2 | EMR on EKS |
|---|---|---|---|
| **Gestión** | Sin cluster — AWS gestiona workers | Cluster EC2 propio | Spark sobre EKS existente |
| **Coste** | Por vCPU/hora de job (solo mientras corre) | EC2 por hora (cluster siempre encendido) | EC2/Fargate del cluster EKS |
| **Arranque job** | 1–3 minutos (pre-init disponible) | Instantáneo (cluster ya encendido) | Minutos |
| **Spot instances** | No — AWS gestiona la capacidad | Sí — Task nodes en Spot (hasta 90% ahorro) | Sí via node groups Spot |
| **Cuándo** | Jobs esporádicos, sin gestionar cluster | Jobs continuos, alta frecuencia, Spot agresivo | Ya tienes EKS, unificar plataforma |
| **Para labs** | ✓ Ideal — pago por job, sin cluster permanente | ⚠️ Coste mínimo aunque no haya jobs | ⚠️ Requiere EKS previo |

**Para los labs:** usamos **EMR Serverless** — sin cluster permanente que olvidar apagado.

---

## Integración EMR con el ecosistema AWS

```
S3 (data lake)        ◄──► EMR lee/escribe S3 directamente (reemplaza HDFS en producción)
Glue Data Catalog     ◄──► EMR usa Glue Catalog como metastore Hive (sin Hive Metastore propio)
Lake Formation        ◄──► EMR respeta permisos de Lake Formation sobre tablas del Catalog
CloudWatch            ◄──► métricas de cluster, logs de aplicación
AWS Glue              ◄──► complementarios: Glue para ETL simple, EMR para batch complejo

Ejemplo de integración:
  Glue Crawler → descubre schema en S3
  Glue Catalog  → almacena el schema
  EMR Spark     → lee "spark.sql('SELECT * FROM glue_catalog.db.table')"
                  sin necesitar Hive Metastore propio
```

---

## EMR con Spot instances — patrón de ahorro

En EMR on EC2 el patrón estándar es:

```
Master node:  On-Demand (1 nodo — no puede interrumpirse)
Core nodes:   On-Demand (persistencia HDFS si es necesaria)
Task nodes:   Spot      (solo procesamiento, hasta 90% ahorro)
```

Si el job no usa HDFS (lee/escribe en S3), incluso los Core nodes pueden ser Spot.

**Cuándo usar EMR + Spot en el examen:** "reducir coste de procesamiento batch", "job tolerante a interrupciones", "data lake en S3 (no HDFS)" → **EMR Task nodes en Spot**.

---

## EMR vs S3 + HDFS

En producción moderna con EMR, **S3 es el storage layer, no HDFS**:

```
EMR moderno (recomendado):
  EMR cluster ─── lee de S3, procesa en memoria, escribe a S3
  HDFS: solo para datos temporales inter-stage (shuffle)
  Ventaja: el cluster puede terminarse sin perder datos

EMR legacy (no recomendado para nuevos proyectos):
  EMR cluster ─── almacena datos en HDFS (discos EC2)
  Problema: datos se pierden si el cluster termina
             cluster no puede escalarse fácilmente
```

**Regla:** En arquitecturas de data lake, EMR siempre lee/escribe S3. HDFS solo para shuffle temporal.
