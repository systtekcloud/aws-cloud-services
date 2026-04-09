# AWS Data & Streaming Services — Labs Prácticos

> **Módulo:** `data/` — Prompts para Claude Code  
> **Repo:** github.com/systtekcloud/aws-cloud-services  
> **Región:** eu-west-1 | **Stack:** AWS CLI v2 + Terraform ≥ 1.7 + Terragrunt (lab05)  
> **Objetivo:** Entender el rol de cada servicio en arquitecturas de datos y streaming

---

## Contexto del módulo

Este módulo cubre los servicios de AWS orientados a procesamiento de datos, streaming y analytics. El objetivo no es solo preparar el SAA-C03 sino construir criterio real sobre cuándo usar cada servicio en arquitecturas de datos modernas.

**Filosofía:** Cada lab debe responder a "¿cuándo usaría esto en un proyecto real?" antes que "¿qué pregunta puede caer en el examen?".

---

## Mapa de servicios y su rol

```
Ingesta de datos:
  Kinesis Data Streams    → streaming en tiempo real, múltiples consumers
  Kinesis Data Firehose   → ingesta managed hacia S3/Redshift/OpenSearch
  Kinesis Data Analytics  → SQL/Flink sobre streams en tiempo real
  MSK (Managed Kafka)     → Kafka gestionado, ecosistema Kafka existente

Procesamiento:
  EMR                     → Spark/Hadoop para procesamiento batch masivo
  Glue                    → ETL serverless, catálogo de datos

Almacenamiento analítico:
  S3                      → data lake foundation
  Redshift                → data warehouse SQL a escala de PB
  OpenSearch              → búsqueda y analytics sobre logs/eventos

Gobierno y consulta:
  Lake Formation          → gobierno y seguridad del data lake
  Athena                  → SQL sobre S3 sin mover datos
```

---

## Tabla de decisión rápida — para el examen

| Necesidad | Servicio |
|-----------|----------|
| Streaming tiempo real + múltiples consumers | Kinesis Data Streams |
| Ingesta managed hacia S3/Redshift | Kinesis Firehose |
| SQL/Flink sobre streams en tiempo real | Kinesis Data Analytics |
| Ecosistema Kafka existente | MSK |
| ETL serverless simple | Glue ETL |
| Catálogo de metadatos compartido | Glue Data Catalog |
| Procesamiento Spark/Hadoop a escala | EMR |
| SQL sobre S3 sin mover datos (ad-hoc) | Athena |
| Data warehouse SQL analítico predecible | Redshift |
| Búsqueda y analytics sobre logs/eventos | OpenSearch |
| Gobierno y seguridad del data lake | Lake Formation |

---

## Lab 01 — Kinesis Data Streams + Firehose

**Por qué:** Kinesis es el servicio de streaming más frecuente en SAA-C03. La confusión entre Streams y Firehose aparece constantemente.  
**Coste:** Muy bajo (~$0.50/hora de lab)  
**Tiempo estimado:** 90 minutos

### Prompt para Claude Code

```
Contexto: Repo aws-cloud-services en github.com/systtekcloud/aws-cloud-services
Mismo estilo que los módulos vpc/, compute/, ecs/ ya existentes.
Región: eu-west-1. Herramientas: AWS CLI v2 + Terraform >= 1.7

Crea el módulo data/labs/lab01-kinesis/ con esta estructura:

1. concept-map/README.md:
   - Qué es Kinesis Data Streams vs Kinesis Data Firehose — diferencia crítica:
     KDS:      → streaming en tiempo real, múltiples consumers independientes,
                 retención configurable (1-365 días), tienes que gestionar consumers
     Firehose: → managed delivery hacia destinos (S3, Redshift, OpenSearch),
                 sin gestión de consumers, near real-time (buffer 60 seg mínimo)
   - Conceptos KDS: Shard, Partition Key, Sequence Number, Consumer, Retention
   - Cuándo KDS vs Firehose vs SQS:
     KDS:     múltiples consumers diferentes procesando el mismo stream
     Firehose: quieres que los datos lleguen a S3/Redshift sin gestión
     SQS:     cola de mensajes punto a punto, procesamiento async
   - Capacidad: 1 shard = 1MB/seg entrada, 2MB/seg salida, 1000 records/seg
   - Enhanced Fan-Out: consumer dedicado con 2MB/seg por consumer (no compartido)
   - Analogía DevOps: KDS ≈ Kafka topic. Firehose ≈ Logstash hacia S3.

2. labs/01-kinesis-data-streams/README.md:
   - Crear KDS con 2 shards via CLI
   - Enviar records: aws kinesis put-record con PartitionKey
   - Consumir records: GetShardIterator → GetRecords
   - Entender: ShardIterator, SequenceNumber, PartitionKey
   - Verificar retención y cómo afecta al coste
   - Script validate.sh

3. labs/02-kinesis-firehose/README.md:
   - Crear Delivery Stream: KDS → Firehose → S3
   - Configurar buffer: 60 segundos o 1MB (lo que ocurra primero)
   - Enviar datos y verificar que llegan a S3 con prefijo fecha/hora
   - Habilitar transformación con Lambda (inline processing)
   - Comparar: con Firehose no necesitas gestionar consumers
   - Documentar: cuándo Firehose es suficiente vs cuándo necesitas KDS directo

4. labs/03-architecture-patterns/README.md:
   - Patrón 1: IoT sensors → KDS → Lambda (alert) + Firehose → S3 (archive)
     → Un stream, dos consumers distintos simultáneamente
   - Patrón 2: App logs → Firehose → S3 → Athena queries
     → Pipeline managed end-to-end sin gestión
   - Patrón 3: KDS → Kinesis Data Analytics → detección anomalías tiempo real
   - Para cada patrón: diagrama ASCII + comandos CLI de prueba

5. terraform/main.tf:
   - aws_kinesis_stream (KDS con 2 shards)
   - aws_kinesis_firehose_delivery_stream (KDS → S3)
   - aws_s3_bucket para destino Firehose
   - aws_lambda_function para transformación inline
   - IAM roles necesarios
   - Outputs: stream ARN, firehose ARN, bucket name

6. scenarios/README.md:
   - 5 escenarios SAA-C03 sobre Kinesis
   - Incluir: KDS vs SQS vs SNS — tabla de decisión
   - Incluir: cuándo usar Enhanced Fan-Out en KDS
   - Incluir: Firehose vs Lambda para transformación

7. cleanup.md: eliminar todos los recursos en orden correcto

Coste estimado: ~$0.50/hora de lab
Tiempo estimado: 90 minutos
```

---

## Lab 02 — Kinesis Data Analytics (Managed Apache Flink)

**Por qué:** KDA permite procesar streams en tiempo real con SQL o Flink. Aparece en SAA-C03 en contextos de detección de anomalías y aggregaciones sobre streams.  
**Coste:** Bajo (~$0.50/hora)  
**Tiempo estimado:** 60 minutos

### Prompt para Claude Code

```
Contexto: Repo aws-cloud-services en github.com/systtekcloud/aws-cloud-services
Mismo estilo que los módulos vpc/, compute/, ecs/ ya existentes.
Región: eu-west-1. Herramientas: AWS CLI v2 + Terraform >= 1.7

Crea el módulo data/labs/lab02-kinesis-analytics/ con esta estructura:

1. concept-map/README.md:
   - Qué es Kinesis Data Analytics (ahora Managed Apache Flink):
     → Procesa streams KDS o MSK en tiempo real con Flink o SQL
     → Serverless — sin gestión de cluster
     → Casos de uso: aggregaciones en tiempo real, detección de anomalías,
       enriquecimiento de datos, joins entre streams
   - Cuándo KDA vs Lambda para procesar KDS:
     KDA/Flink: → aggregaciones con ventanas temporales (tumbling, sliding),
                  joins entre streams, stateful processing complejo
     Lambda:    → transformaciones simples registro a registro,
                  lógica de negocio simple, integración con otros servicios AWS
   - Conceptos Flink: Source, Sink, Operator, Window (Tumbling/Sliding/Session)
   - Analogía DevOps: KDA ≈ pipeline de transformación en tiempo real
                       como un job de CI/CD pero para datos en streaming

2. labs/01-sql-analytics/README.md:
   - Crear KDA application con SQL
   - Source: KDS con datos de temperatura de sensores (simulados)
   - Query SQL: promedio de temperatura por sensor en ventana de 1 minuto
   - Sink: Firehose → S3
   - Verificar resultados aggregados en S3
   - Script validate.sh

3. labs/02-anomaly-detection/README.md:
   - Usar función RANDOM_CUT_FOREST de KDA para detección de anomalías
   - Source: KDS con métricas de aplicación (CPU, latencia)
   - Detectar spikes anómalos automáticamente sin threshold fijo
   - Sink: KDS output → Lambda → SNS alerta
   - Documentar: KDA Anomaly Detection vs CloudWatch Anomaly Detection

4. terraform/main.tf:
   - aws_kinesisanalyticsv2_application
   - KDS source y sink
   - IAM roles necesarios
   - Outputs: application ARN

5. scenarios/README.md:
   - 3 escenarios SAA-C03 sobre KDA
   - Incluir: KDA vs Lambda para procesamiento de streams
   - Incluir: ventanas temporales — cuándo tumbling vs sliding

6. cleanup.md

Coste estimado: ~$0.50/hora
Tiempo estimado: 60 minutos
```

---

## Lab 03 — Amazon MSK (Managed Streaming for Kafka)

**Por qué:** MSK aparece en SAA-C03 cuando hay ecosistema Kafka existente. La decisión MSK vs Kinesis es frecuente.  
**Coste:** ~$0.50/hora (MSK Serverless)  
**Tiempo estimado:** 60 minutos

### Prompt para Claude Code

```
Contexto: Repo aws-cloud-services en github.com/systtekcloud/aws-cloud-services
Mismo estilo que los módulos vpc/, compute/, ecs/ ya existentes.
Región: eu-west-1. Herramientas: AWS CLI v2 + Terraform >= 1.7

Crea el módulo data/labs/lab03-msk/ con esta estructura:

1. concept-map/README.md:
   - Qué es MSK: Kafka gestionado por AWS
   - Cuándo MSK vs Kinesis — decisión crítica para el examen:
     MSK:     → ya tienes ecosistema Kafka on-prem o existente,
                necesitas Kafka-compatible APIs, Kafka Connect,
                Kafka Streams, más control sobre configuración,
                equipos con experiencia en Kafka
     Kinesis: → empiezas desde cero en AWS, quieres menos gestión,
                integración nativa con servicios AWS, sin experiencia Kafka
   - MSK Serverless vs MSK Provisioned:
     Serverless:  → sin gestión de capacidad, pago por uso
     Provisioned: → control total sobre brokers y almacenamiento
   - MSK Connect: connectors managed (S3 Sink, DynamoDB Sink...)
   - Analogía DevOps: MSK ≈ RDS pero para Kafka

2. labs/01-msk-cluster/README.md:
   - Crear cluster MSK Serverless
   - Crear topic via Kafka CLI
   - Producir y consumir mensajes
   - Verificar métricas en CloudWatch
   - Script validate.sh

3. labs/02-msk-connect/README.md:
   - Configurar S3 Sink Connector: MSK → S3
   - Verificar que los mensajes llegan a S3
   - Documentar: MSK Connect vs Lambda consumer

4. terraform/main.tf:
   - aws_msk_serverless_cluster
   - aws_security_group para MSK
   - VPC y subnets (MSK requiere multi-AZ)
   - IAM roles necesarios

5. scenarios/README.md:
   - 3 escenarios SAA-C03 sobre MSK
   - Incluir: MSK vs Kinesis — tabla de decisión completa
   - Incluir: MSK para migración lift-and-shift de Kafka on-prem

6. cleanup.md

Coste estimado: ~$0.50/hora (MSK Serverless)
Tiempo estimado: 60 minutos
```

---

## Lab 04 — AWS Glue + Lake Formation

**Por qué:** Glue ETL y Lake Formation son frecuentes en SAA-C03 en contexto de data lakes.  
**Coste:** Bajo (Glue crawlers por minuto, Athena por TB escaneado)  
**Tiempo estimado:** 90 minutos

### Prompt para Claude Code

```
Contexto: Repo aws-cloud-services en github.com/systtekcloud/aws-cloud-services
Mismo estilo que los módulos vpc/, compute/, ecs/ ya existentes.
Región: eu-west-1. Herramientas: AWS CLI v2 + Terraform >= 1.7

Crea el módulo data/labs/lab04-glue-lakeformation/ con esta estructura:

1. concept-map/README.md:
   - AWS Glue — tres componentes distintos (confusión frecuente en el examen):
     Glue Data Catalog: → metastore centralizado (como Hive Metastore)
                          tablas, schemas, particiones
                          usado por Athena, EMR, Redshift Spectrum
     Glue Crawlers:     → descubren datos en S3/RDS y crean tablas en Catalog
     Glue ETL Jobs:     → scripts Spark serverless para transformar datos
   - Lake Formation — gobierno del data lake:
     → Control de acceso fino sobre datos en S3 (column-level, row-level)
     → Centraliza permisos de múltiples servicios (Athena, EMR, Glue)
   - Analogía DevOps:
     Glue Catalog ≈ schema registry
     Glue ETL ≈ pipeline de transformación como job de CI/CD para datos
     Lake Formation ≈ RBAC para el data lake

2. labs/01-glue-catalog/README.md:
   - Subir dataset CSV de prueba a S3 (datos ficticios)
   - Crear Glue Crawler que descubre el schema automáticamente
   - Verificar tabla creada en Glue Data Catalog
   - Consultar la tabla con Athena sin mover datos
   - Script validate.sh

3. labs/02-glue-etl/README.md:
   - Crear Glue ETL Job (Python Shell)
   - Transformación: CSV en S3 → Parquet en S3
   - Verificar que Athena consulta más rápido y barato con Parquet
   - Documentar: por qué Parquet/ORC > CSV para analytics

4. labs/03-lake-formation/README.md:
   - Habilitar Lake Formation
   - Registrar S3 bucket como data lake location
   - Configurar permisos: usuario A puede ver tabla X, usuario B no
   - Verificar que Athena respeta los permisos de Lake Formation
   - Documentar: Lake Formation vs S3 bucket policies

5. terraform/main.tf:
   - aws_glue_catalog_database, aws_glue_crawler, aws_glue_job
   - aws_lakeformation_resource, aws_lakeformation_permissions
   - S3 buckets (raw y processed)
   - IAM roles necesarios

6. scenarios/README.md:
   - 4 escenarios SAA-C03 sobre Glue y Lake Formation
   - Incluir: Glue vs EMR para ETL
   - Incluir: Athena vs Redshift
   - Incluir: Lake Formation vs S3 policies para gobierno

7. cleanup.md

Coste estimado: ~$2-5 por lab completo
Tiempo estimado: 90 minutos
```

---

## Lab 05 — Amazon EMR

**Por qué:** EMR es la solución para procesamiento Spark/Hadoop a escala.  
**Coste:** ~$1-2/hora  
**Tiempo estimado:** 60 minutos

### Prompt para Claude Code

```
Contexto: Repo aws-cloud-services en github.com/systtekcloud/aws-cloud-services
Mismo estilo que los módulos vpc/, compute/, ecs/ ya existentes.
Región: eu-west-1. Herramientas: AWS CLI v2 + Terraform >= 1.7

⚠️ COSTE: Terminar el cluster inmediatamente tras el lab.

Crea el módulo data/labs/lab05-emr/ con esta estructura:

1. concept-map/README.md:
   - Qué es EMR: cluster Hadoop/Spark gestionado
   - Cuándo EMR vs Glue ETL — decisión clave:
     EMR:  → control total, frameworks custom (Spark, Hive, Presto, HBase),
              workloads que necesitan tuning avanzado, PBs de datos,
              ML con Spark MLlib, equipos con experiencia Spark
     Glue: → ETL serverless sin gestión de cluster, menos control,
              suficiente para mayoría de pipelines ETL simples
   - EMR Serverless vs EMR on EC2 vs EMR on EKS:
     Serverless: → sin gestión de cluster, pago por uso
     on EC2:     → control total, Spot para Task nodes
     on EKS:     → Spark sobre Kubernetes existente
   - Integración: EMR lee/escribe S3, usa Glue Catalog como metastore
   - Analogía DevOps: EMR ≈ cluster Kubernetes pero para datos

2. labs/01-emr-serverless/README.md:
   - Crear EMR Serverless application
   - Enviar job Spark simple: contar palabras en dataset S3
   - Verificar output en S3
   - Explorar logs en CloudWatch
   - Script validate.sh
   - ⚠️ cleanup inmediato

3. labs/02-emr-glue-integration/README.md:
   - EMR usa Glue Data Catalog como metastore
   - Job Spark que lee tabla del Catalog → procesa → escribe S3
   - Comparar: EMR vs Glue ETL para el mismo job
   - Documentar: cuándo EMR justifica su complejidad

4. terraform/main.tf:
   - aws_emr_serverless_application
   - S3 buckets (input, output, logs)
   - IAM roles necesarios

5. scenarios/README.md:
   - 3 escenarios SAA-C03 sobre EMR
   - Incluir: EMR vs Glue vs Athena — tabla de decisión
   - Incluir: EMR con Spot instances para Task nodes
   - Incluir: EMR + S3 como data lake vs HDFS

6. cleanup.md: ⚠️ CRÍTICO

Coste estimado: ~$1-2 por lab (EMR Serverless paga por vCPU/hora de job)
Tiempo estimado: 60 minutos
```

---

## Lab 06 — Amazon Redshift

**Por qué:** Redshift vs Athena es una de las preguntas más frecuentes en SAA-C03. La distinción data warehouse vs data lake es fundamental.  
**Coste:** ~$0.25/hora (dc2.large nodo único para labs)  
**Tiempo estimado:** 60 minutos

### Prompt para Claude Code

```
Contexto: Repo aws-cloud-services en github.com/systtekcloud/aws-cloud-services
Mismo estilo que los módulos vpc/, compute/, ecs/ ya existentes.
Región: eu-west-1. Herramientas: AWS CLI v2 + Terraform >= 1.7

⚠️ COSTE: Pausar o eliminar el cluster Redshift al terminar el lab.

Crea el módulo data/labs/lab06-redshift/ con esta estructura:

1. concept-map/README.md:
   - Qué es Redshift: data warehouse SQL columnar a escala de PB
   - Cuándo Redshift vs Athena — distinción CRÍTICA para el examen:
     Redshift:
       → Schema-on-write (defines estructura antes de cargar)
       → Datos estructurados y limpios
       → Queries SQL predecibles y recurrentes (dashboards, BI)
       → Alto rendimiento para queries complejas con JOINs
       → Concurrencia alta de usuarios
       → Coste fijo (cluster siempre encendido)
     Athena:
       → Schema-on-read (consultas sobre datos raw en S3)
       → Datos en cualquier formato (CSV, Parquet, JSON, ORC)
       → Queries ad-hoc, exploración, análisis ocasional
       → Pago por datos escaneados (sin infraestructura)
       → Ideal para data lake queries sin mover datos
   - Redshift Spectrum: Redshift consulta datos en S3 directamente
   - Redshift Serverless vs Provisioned:
     Serverless:  → sin gestión de cluster, pago por uso (RPU/hora)
     Provisioned: → control total, reserva de capacidad
   - Analogía DevOps: Redshift ≈ base de datos optimizada para lectura
                       como un RDS pero para analytics a escala

2. labs/01-redshift-basics/README.md:
   - Crear cluster Redshift Serverless (más barato para labs)
   - Cargar datos desde S3 via COPY command
   - Ejecutar queries analíticas: GROUP BY, agregaciones, JOINs
   - Comparar rendimiento vs Athena sobre los mismos datos
   - Script validate.sh

3. labs/02-redshift-spectrum/README.md:
   - Configurar Redshift Spectrum
   - Crear external schema apuntando a Glue Data Catalog
   - Query que combina tablas Redshift (hot data) + S3 via Spectrum (cold data)
   - Documentar: cuándo Spectrum vs mover datos a Redshift

4. terraform/main.tf:
   - aws_redshift_serverless_namespace
   - aws_redshift_serverless_workgroup
   - S3 bucket para datos de carga
   - IAM roles necesarios (Redshift necesita rol para acceder S3)
   - Outputs: endpoint, workgroup ARN

5. scenarios/README.md:
   - 4 escenarios SAA-C03 sobre Redshift
   - Incluir: Redshift vs Athena — tabla de decisión completa
   - Incluir: Redshift Spectrum para datos históricos en S3
   - Incluir: Firehose → Redshift para ingesta streaming
   - Incluir: Redshift Multi-AZ para HA

6. cleanup.md: ⚠️ Pausar o eliminar workgroup

Coste estimado: ~$0.25/hora (Redshift Serverless por RPU)
Tiempo estimado: 60 minutos
```

---

## Lab 07 — Amazon OpenSearch Service

**Por qué:** OpenSearch aparece en SAA-C03 para búsqueda sobre logs, analytics en tiempo real y como destino de Firehose.  
**Coste:** ~$0.50/hora (instancia t3.small)  
**Tiempo estimado:** 45 minutos

### Prompt para Claude Code

```
Contexto: Repo aws-cloud-services en github.com/systtekcloud/aws-cloud-services
Mismo estilo que los módulos vpc/, compute/, ecs/ ya existentes.
Región: eu-west-1. Herramientas: AWS CLI v2 + Terraform >= 1.7

⚠️ COSTE: Eliminar el dominio OpenSearch al terminar — cobra por hora.

Crea el módulo data/labs/lab07-opensearch/ con esta estructura:

1. concept-map/README.md:
   - Qué es OpenSearch (antes Elasticsearch Service):
     → Motor de búsqueda y analytics distribuido
     → Búsqueda full-text, faceted search, agregaciones
     → Kibana/OpenSearch Dashboards para visualización
   - Cuándo OpenSearch vs Athena vs Redshift:
     OpenSearch: → búsqueda full-text, logs analytics en tiempo real,
                   queries sobre datos no estructurados o semi-estructurados,
                   dashboards operacionales de logs
     Athena:     → SQL ad-hoc sobre S3, datos estructurados, bajo coste
     Redshift:   → SQL analítico predecible, datos estructurados, BI
   - Patrones frecuentes:
     CloudWatch Logs → Firehose → OpenSearch (log analytics)
     Kinesis → Firehose → OpenSearch (eventos en tiempo real)
   - Analogía DevOps: OpenSearch ≈ ELK Stack gestionado en AWS

2. labs/01-opensearch-basics/README.md:
   - Crear dominio OpenSearch (t3.small para labs)
   - Indexar documentos via REST API
   - Queries: full-text search, filtros, agregaciones
   - Abrir OpenSearch Dashboards y crear visualización básica
   - Script validate.sh

3. labs/02-logs-pipeline/README.md:
   - Pipeline: CloudWatch Logs → Subscription Filter → Firehose → OpenSearch
   - Indexar logs de Lambda automáticamente
   - Crear dashboard en OpenSearch Dashboards:
     → Errores por hora
     → Latencia promedio
     → Top endpoints
   - Documentar: este patrón vs CloudWatch Logs Insights

4. terraform/main.tf:
   - aws_opensearch_domain (t3.small.search)
   - aws_kinesis_firehose_delivery_stream (→ OpenSearch)
   - aws_cloudwatch_log_subscription_filter
   - IAM roles y resource policies de OpenSearch
   - Outputs: endpoint, dashboard URL

5. scenarios/README.md:
   - 3 escenarios SAA-C03 sobre OpenSearch
   - Incluir: OpenSearch vs CloudWatch Logs Insights para log analytics
   - Incluir: Firehose → OpenSearch pipeline completo
   - Incluir: OpenSearch para búsqueda en aplicación vs RDS LIKE queries

6. cleanup.md: ⚠️ Eliminar dominio — cobra por hora aunque no haya datos

Coste estimado: ~$0.50/hora
Tiempo estimado: 45 minutos
```

---

## Lab 08 — Data Lake Architecture (Integrador con Terragrunt)

**Por qué:** Integra todos los servicios anteriores en una arquitectura real end-to-end con IaC enterprise.  
**Coste:** ~$5-10 por lab completo  
**Tiempo estimado:** 120 minutos

### Prompt para Claude Code

```
Contexto: Repo aws-cloud-services en github.com/systtekcloud/aws-cloud-services
Mismo estilo que compute/v5 y ecs/v7 (enterprise con Terragrunt).
Región: eu-west-1.
Herramientas: AWS CLI v2 + Terraform >= 1.7 + Terragrunt >= 0.54

Este lab es el integrador del módulo data/ — combina todos los servicios
anteriores en una arquitectura de data lake production-ready con IaC enterprise.

Crea el módulo data/labs/lab08-data-lake-terragrunt/ con esta estructura:

1. concept-map/README.md:
   - Arquitectura Lambda Pattern (patrón de datos, no AWS Lambda):
     Batch layer:  → Glue/EMR procesa datos históricos → S3 (processed)
     Speed layer:  → Kinesis procesa datos en tiempo real → resultados inmediatos
     Serving layer → Athena/Redshift Spectrum sirve queries combinadas
   - Arquitectura Kappa (simplificada):
     → Solo streaming (Kinesis/MSK) → re-procesamiento del stream
     → Reemplaza el batch layer — más simple, menos componentes
   - Data Lake vs Data Warehouse:
     Data Lake (S3 + Glue + Athena):
       → Schema-on-read, datos raw + procesados, barato, flexible
       → Para: exploración, ML, datos no estructurados/semi-estructurados
     Data Warehouse (Redshift):
       → Schema-on-write, datos estructurados, rápido para SQL analítico
       → Para: BI, dashboards, queries SQL complejas predecibles y recurrentes
   - Cuándo usar cada capa en una arquitectura real

2. Estructura Terragrunt:
   data/labs/lab08-data-lake-terragrunt/
   ├── terragrunt.hcl              ← root config (remote state, provider)
   ├── dev/
   │   ├── env.hcl                 ← variables de entorno dev
   │   ├── ingestion/
   │   │   └── terragrunt.hcl      ← KDS + Firehose
   │   ├── processing/
   │   │   └── terragrunt.hcl      ← Glue ETL + EMR Serverless
   │   ├── storage/
   │   │   └── terragrunt.hcl      ← S3 buckets (raw/processed/curated)
   │   ├── serving/
   │   │   └── terragrunt.hcl      ← Redshift Serverless + Athena workgroup
   │   ├── search/
   │   │   └── terragrunt.hcl      ← OpenSearch (opcional en dev)
   │   └── governance/
   │       └── terragrunt.hcl      ← Lake Formation + Glue Catalog
   └── modules/
       ├── ingestion/main.tf        ← módulo reutilizable KDS/Firehose
       ├── processing/main.tf       ← módulo reutilizable Glue/EMR
       ├── storage/main.tf          ← módulo reutilizable S3 + lifecycle
       ├── serving/main.tf          ← módulo reutilizable Redshift/Athena
       └── governance/main.tf       ← módulo reutilizable LakeFormation

3. labs/01-batch-pipeline/README.md:
   - Pipeline batch completo con Terragrunt:
     terragrunt run-all apply en storage/ + processing/ + serving/
   - S3 (raw CSV) → Glue Crawler → Glue Catalog
     → Glue ETL Job → S3 (Parquet procesado)
     → Athena queries sobre datos procesados
   - Medir: coste y tiempo de query antes/después de convertir a Parquet

4. labs/02-streaming-pipeline/README.md:
   - Pipeline streaming con Terragrunt:
     terragrunt run-all apply en ingestion/ + storage/ + serving/
   - Kinesis Data Streams → Firehose → S3
     → Glue Crawler (actualiza schema automáticamente)
     → Athena queries (near real-time)
   - Simular productor de datos con script Python
   - Añadir KDA (Kinesis Data Analytics) para aggregaciones en tiempo real

5. labs/03-combined-architecture/README.md:
   - Arquitectura Lambda Pattern completa:
     Producers → KDS → Lambda (alertas tiempo real)
                     → Firehose → S3 (raw)
                                   → Glue ETL → S3 (processed/Parquet)
                                                  → Redshift Spectrum
                                                  → Athena (ad-hoc)
                                                  → OpenSearch (log analytics)
   - Lake Formation controla acceso a todas las capas
   - Diagrama ASCII completo de la arquitectura
   - Documentar: qué capa responde a qué tipo de pregunta de negocio

6. labs/04-governance/README.md:
   - Lake Formation como capa de gobierno:
     → Permisos a nivel de tabla, columna y fila
     → Usuario analista: acceso solo a tablas procesadas, sin columnas PII
     → Usuario data engineer: acceso a raw + processed
     → Usuario BI: acceso solo a curated (Redshift)
   - Auditoría: CloudTrail registra cada acceso a datos via Lake Formation

7. scenarios/README.md:
   - 8 escenarios de arquitectura SAA-C03 integradores:
   - Incluir: cuándo Redshift vs Athena
   - Incluir: cuándo Kinesis vs MSK vs SQS para ingesta
   - Incluir: Lake Formation vs S3 bucket policies
   - Incluir: EMR vs Glue para transformación masiva
   - Incluir: OpenSearch vs CloudWatch Logs Insights
   - Incluir: data lake architecture para cumplimiento GDPR
   - Incluir: Kappa vs Lambda architecture — cuándo simplificar
   - Incluir: Firehose → Redshift vs Glue ETL → Redshift

8. cleanup.md:
   - terragrunt run-all destroy en orden inverso
   - Verificar que no quedan recursos (Redshift y OpenSearch cobran por hora)
   - Lista de verificación de recursos eliminados

Coste estimado: ~$5-10 por lab completo
Tiempo estimado: 120 minutos
Nota: Diseñado para ser el lab más completo del módulo.
      Reutiliza módulos de labs anteriores.
```

---

## Estructura final del módulo

```
data/
├── README.md                              ← este documento
└── labs/
    ├── lab01-kinesis/                     ⏳ Pendiente (~$0.50/h)
    ├── lab02-kinesis-analytics/           ⏳ Pendiente (~$0.50/h)
    ├── lab03-msk/                         ⏳ Pendiente (~$0.50/h)
    ├── lab04-glue-lakeformation/          ⏳ Pendiente (~$2-5 lab)
    ├── lab05-emr/                         ⏳ Pendiente (~$1-2/h)
    ├── lab06-redshift/                    ⏳ Pendiente (~$0.25/h)
    ├── lab07-opensearch/                  ⏳ Pendiente (~$0.50/h)
    └── lab08-data-lake-terragrunt/        ⏳ Pendiente (~$5-10 lab)
        ├── terragrunt.hcl
        ├── dev/
        │   ├── ingestion/
        │   ├── processing/
        │   ├── storage/
        │   ├── serving/
        │   ├── search/
        │   └── governance/
        └── modules/
```

---

*Repo: github.com/systtekcloud/aws-cloud-services | Módulo: data/*
