# Escenarios SAA-C03 — Data Lake Integrador

> 8 escenarios que cubren los servicios del lab08: Kinesis, Glue, EMR, Redshift, Athena, Lake Formation, OpenSearch y Terragrunt como práctica de arquitectura.

---

## Escenario 1: Diseño de data lake — elegir las capas correctas

**Pregunta:** Una empresa de retail procesa 10 millones de transacciones diarias. Necesitan:
- Almacenar todos los datos crudos indefinidamente (coste mínimo)
- Transformar y limpiar los datos para análisis
- Dashboards diarios de ventas en QuickSight (respuesta < 2 segundos)
- Análisis ad-hoc exploratorio para científicos de datos (queries no predecibles)
- Compliance: los analistas de negocio no pueden ver datos de tarjeta de crédito

¿Cuál es la arquitectura correcta?

**A)** Todo en Redshift Serverless — una única fuente de verdad SQL
**B)** S3 raw + Glue ETL + Athena para todo (ad-hoc y dashboards)
**C)** S3 raw + Glue ETL → S3 processed (Athena ad-hoc) + Redshift Serverless (BI) + Lake Formation (PII)
**D)** Kinesis → OpenSearch para todo (streaming analytics + dashboards)

**Respuesta: C**

**Por qué:**

```
Requisito                  Servicio            Razón
─────────────────────────────────────────────────────────────
Almacenar raw forever      S3 + lifecycle      $0.023/GB; Glacier IR tras 90d
Transformar/limpiar        Glue ETL            CSV→Parquet Snappy, schema gestión
Dashboards BI recurrentes  Redshift Serverless Rendimiento predecible, cargado con COPY
Análisis ad-hoc            Athena              Schema-on-read, $5/TB, no requiere carga previa
Control PII                Lake Formation      Column-level security sobre Athena y Glue
```

**Por qué no (A):** Redshift no es barato para almacenar histórico sin comprimir.
**Por qué no (B):** Athena es más lenta y cara que Redshift para dashboards recurrentes con JOINs complejos.
**Por qué no (D):** OpenSearch no es un data warehouse; no soporta SQL analítico ni queries JOIN complejas.

**Regla del examen:** "Data lake completo" = S3 raw + Glue ETL + Athena (ad-hoc) + Redshift (BI) + Lake Formation (PII).

---

## Escenario 2: Glue Crawler vs schema manual

**Pregunta:** Un equipo de data engineering recibe archivos CSV de 50 proveedores distintos cada hora en S3. Los schemas cambian frecuentemente (nuevas columnas, tipos distintos). ¿Cómo gestionar los schemas en el Glue Data Catalog?

**A)** Crear tablas manualmente en el Glue Catalog mediante AWS Console para cada proveedor
**B)** Usar Glue Crawlers que se ejecuten cada hora y detecten cambios de schema automáticamente
**C)** Cargar todos los CSVs en Redshift con `COPY` y usar las columnas de Redshift como schema
**D)** Usar Lambda para parsear cada CSV y crear tablas Glue via API cuando llegan archivos nuevos

**Respuesta: B — Glue Crawlers programados**

**Por qué:**
- 50 proveedores × cambios frecuentes = imposible de mantener manualmente (A)
- `schema_change_policy = UPDATE_IN_DATABASE` → el Crawler actualiza el schema cuando detecta columnas nuevas
- El Crawler puede ejecutarse en schedule (EventBridge cron) cada hora para detectar nuevos datos y schemas
- Los Crawlers detectan automáticamente particiones nuevas (`year=.../month=...`) y las añaden al Catalog
- Lambda (D) reinventa la rueda: Glue Crawlers ya hacen exactamente esto

**Cuándo usar schema manual:** cuando el schema es estable y controlado, no viene de terceros.

**Regla del examen:** "Schema desconocido", "datos de terceros", "schema cambia frecuentemente" → **Glue Crawler**.

---

## Escenario 3: EMR Serverless vs Glue ETL

**Pregunta:** Un equipo de ML necesita procesar 500 GB de datos de clickstream con PySpark: enriquecer eventos con datos de un modelo ML (librería scikit-learn), aplicar joins complejos con 10 tablas, y escribir features en Parquet. El proceso tarda 4 horas. ¿Qué servicio usar?

**A)** Glue ETL Job con G.2X workers
**B)** EMR Serverless con Spark 3.5
**C)** Lambda con acceso a S3 (procesamiento en paralelo con SQS)
**D)** Glue ETL con modo streaming (Glue Streaming ETL Job)

**Respuesta: B — EMR Serverless**

**Por qué:**

```
Glue ETL (A):
  + Managed (no gestionar cluster)
  + Integración nativa con Glue Catalog
  - Limitado a librerías preinstaladas (+ carga desde S3)
  - Glue Streaming es para microbatch, no para jobs de 4 horas
  - Timeout máximo de Glue Job = 48 horas, pero G.2X tiene menos flexibilidad

EMR Serverless (B):
  + Librerías customizadas (scikit-learn, XGBoost, etc.) en el entrypoint
  + Jobs Spark de larga duración (horas)
  + `maximum_capacity` controla el coste máximo
  + Acceso nativo al Glue Catalog como Hive metastore
  + Sin cluster que gestionar (serverless)
  ✓ Correcto para ML + Spark custom + 4 horas
```

**Lambda (C):** Lambda tiene timeout de 15 minutos y memoria limitada (10GB). Para 500GB de datos distribuidos, necesitas Spark.

**Regla del examen:** "PySpark custom", "librerías ML", "jobs largos (horas)", "gran volumen" → **EMR Serverless**. "Glue ETL" = para transformaciones estándar sin dependencias custom.

---

## Escenario 4: Redshift Spectrum vs COPY para datos históricos

**Pregunta:** Una empresa tiene 5 años de datos históricos (200 TB) en S3 en formato Parquet, catalogados en Glue. También tienen un Redshift con datos de los últimos 90 días (1 TB) para dashboards. Los analistas quieren hacer queries que combinen datos recientes (Redshift) con histórico (S3). ¿Cuál es la opción más coste-eficiente?

**A)** Cargar los 200 TB en Redshift con COPY
**B)** Usar Redshift Spectrum para acceder a S3 directamente desde Redshift
**C)** Migrar todo a Athena y eliminar Redshift
**D)** Usar Glue ETL para fusionar datos históricos con recientes en un único Parquet y cargar en Redshift

**Respuesta: B — Redshift Spectrum**

**Por qué:**

```
Opción A (COPY 200 TB):
  Coste Redshift: 200 TB × coste de almacenamiento Redshift
  Redshift RA3 almacena en RMS (S3-backed) → ~$0.024/GB/mes
  200 TB × $24/mes = $4,800/mes solo en almacenamiento
  + Los datos ya están en S3 → duplicación innecesaria

Opción B (Spectrum):
  Los 200 TB permanecen en S3 ($0.023/GB → $4,600/mes, pero posiblemente ya pagado)
  Spectrum lee de S3 bajo demanda → $5/TB escaneado
  Redshift accede via Glue Catalog → JOIN entre hot data + cold data sin mover nada
  ✓ Sin duplicación, sin carga, acceso inmediato

Opción C (solo Athena):
  Athena no tiene caché ni memoria → cada dashboard query rescana S3
  Redshift es mucho más rápido para dashboards con filtros complejos

Opción D (ETL mensual):
  Costoso en procesamiento Glue; no resuelve la necesidad ad-hoc
```

**Regla del examen:** "Datos históricos en S3 + datos recientes en Redshift", "sin querer mover datos", "JOIN entre hot y cold" → **Redshift Spectrum**.

---

## Escenario 5: Terragrunt — gestión de dependencias entre módulos

**Pregunta:** Un equipo usa Terragrunt para desplegar un data lake con 5 módulos (storage, governance, ingestion, processing, serving). El módulo `serving` necesita outputs del módulo `governance` (nombre de la Glue DB) y del módulo `storage` (ARN del bucket). ¿Cuál es el patrón correcto para gestionar estas dependencias?

**A)** Copiar manualmente los outputs de `governance` y `storage` en el `terragrunt.hcl` de `serving`
**B)** Usar `dependency {}` blocks en el `terragrunt.hcl` de `serving` para referenciar los outputs de los otros módulos
**C)** Pasar todos los valores como variables de entorno en el pipeline CI/CD
**D)** Usar un módulo Terraform "umbrella" que despliegue todo junto con `module {}` blocks

**Respuesta: B — `dependency {}` blocks**

**Por qué:**

```
Opción A (hardcoding):
  Los outputs son dinámicos (bucket name incluye account_id)
  Hardcodear rompe cuando se despliega en otra cuenta o región

Opción B (dependency blocks):
  dependency "storage" {
    config_path = "../storage"
    mock_outputs = { data_lake_bucket_arn = "arn:aws:s3:::mock" }
  }
  inputs = {
    data_lake_bucket_arn = dependency.storage.outputs.data_lake_bucket_arn
  }
  ✓ Resuelve automáticamente el orden de apply
  ✓ mock_outputs permite hacer plan sin que storage esté desplegado
  ✓ terragrunt run-all apply respeta las dependencias

Opción C (env vars):
  Frágil: si olvidar exportar una var, el pipeline falla de forma críptica

Opción D (módulo umbrella):
  Pierde los beneficios de Terragrunt: state aislado por módulo, apply granular
  Un error en serving requiere plan/apply del todo
```

**Regla del examen:** Terragrunt `dependency {}` = el patrón correcto para compartir outputs entre módulos independientes con state separado.

---

## Escenario 6: Lake Formation — PII y compliance

**Pregunta:** Una empresa financiera debe cumplir con GDPR. Los analistas de negocio pueden ver métricas de transacciones pero NO los datos de cliente (nombre, IBAN, email). El equipo de compliance necesita ver todo. Los datos están en un bucket S3 catalogado en Glue. ¿Cómo implementarlo?

**A)** Crear dos buckets S3 distintos: uno con PII (acceso restringido por IAM) y uno sin PII
**B)** Usar Lake Formation con `ColumnWildcard.ExcludedColumnNames` para excluir columnas PII para el rol analista
**C)** Cifrar las columnas PII con KMS y dar la clave solo al equipo de compliance
**D)** Usar Lambda para leer los datos y filtrar columnas PII antes de enviarlos a los analistas

**Respuesta: B — Lake Formation column-level security**

**Por qué:**

```
Opción A (dos buckets):
  Requiere ETL para copiar y anonimizar datos → duplicación
  Los datos en el bucket "sin PII" son una copia, puede quedar desincronizado
  Mayor coste y complejidad operativa

Opción B (Lake Formation):
  grant-permissions con ColumnWildcard.ExcludedColumnNames = ["nombre", "iban", "email"]
  El rol analista hace SELECT * → LF filtra las columnas automáticamente en Athena/Glue
  Un único dataset, control centralizado, sin copia de datos
  ✓ Soportado nativamente por Athena, Glue, EMR, Redshift Spectrum

Opción C (cifrado KMS):
  El cifrado no filtra columnas — el analista vería datos cifrados ilegibles
  No es una solución de access control, es cifrado at-rest

Opción D (Lambda proxy):
  Reinventar la rueda; escalabilidad dudosa
  Los analistas podrían bypasear Lambda accediendo directamente a S3
```

**Regla del examen:** "Columnas PII", "analistas sin acceso a datos sensibles", "mismo dataset" → **Lake Formation column-level security**.

---

## Escenario 7: Kinesis vs MSK — cuándo usar cada uno

**Pregunta:** Una empresa de IoT conecta 500,000 sensores que envían eventos de telemetría. Los consumidores son: (1) una Lambda que detecta anomalías en tiempo real, (2) un job Spark en EMR que hace analytics cada hora, (3) un sistema on-premises legacy que solo soporta el protocolo Kafka. ¿Qué servicio de streaming usar?

**A)** Kinesis Data Streams para los tres consumidores
**B)** Amazon MSK para los tres consumidores
**C)** Kinesis Data Streams para Lambda y EMR; MSK solo para el sistema legacy
**D)** SQS FIFO para los tres (garantía de orden)

**Respuesta: B — Amazon MSK**

**Por qué:**

```
Requisito clave: "sistema legacy que solo soporta protocolo Kafka"
→ Kinesis tiene una API propietaria; no es compatible con el protocolo Kafka
→ MSK es Kafka gestionado → el sistema legacy puede conectarse sin cambios

Adicionalmente:
  500,000 sensores → alto throughput → MSK Serverless o Provisioned con múltiples particiones
  EMR + Spark → spark-kafka connector (estándar) funciona con MSK
  Lambda → MSK como trigger via Lambda event source mapping (desde 2020)

Opción A (solo Kinesis):
  El sistema legacy no puede consumir de Kinesis sin una capa de traducción
  → No cumple el requisito

Opción C (híbrido):
  Innecesariamente complejo; hay que mantener dos sistemas de streaming

Opción D (SQS FIFO):
  SQS no es adecuado para analytics en tiempo real ni para Spark
  SQS FIFO tiene límite de 300 mensajes/segundo (FIFO standard)
```

**Regla del examen:** "protocolo Kafka", "legacy compatible con Kafka", "migración desde on-prem Kafka" → **MSK**. "AWS-nativo, managed, múltiples consumers, Lambda trigger" → **Kinesis**.

---

## Escenario 8: Elegir la herramienta de IaC — Terraform vs Terragrunt vs CloudFormation

**Pregunta:** Un equipo de plataforma necesita desplegar el mismo data lake en 3 entornos (dev, staging, prod) en 3 cuentas AWS distintas. El código base de Terraform es idéntico excepto por variables de entorno (bucket names, capacidades). El equipo quiere:
- Remote state en S3 con locking en DynamoDB por entorno
- Reutilizar código sin duplicar HCL
- Orden de despliegue automático respetando dependencias
- Capacidad de hacer `apply` solo de un módulo específico sin afectar los demás

¿Qué herramienta de IaC usar?

**A)** Terraform workspaces — un workspace por entorno
**B)** CloudFormation StackSets — desplegar en múltiples cuentas automáticamente
**C)** Terragrunt — un `terragrunt.hcl` raíz + `env.hcl` por entorno + `dependency {}` blocks
**D)** AWS CDK — usar constructs de nivel L2 con `app.synth()` por cuenta

**Respuesta: C — Terragrunt**

**Por qué:**

```
Requisito                          Terragrunt               Terraform Workspaces
─────────────────────────────────────────────────────────────────────────────────
Remote state por entorno           ✓ Automático en S3       ✓ Requiere config manual
Sin duplicación HCL                ✓ DRY con `source =`     ✗ Hay que copiar backend.tf
Dependencias entre módulos         ✓ dependency {} blocks   ✗ No existe
Apply de un módulo específico      ✓ cd dev/storage && tg   ~ Solo con -target (frágil)
Multi-cuenta AWS                   ✓ env.hcl por cuenta     ✗ Workspaces = misma cuenta
```

**CloudFormation StackSets (B):** excelente para multi-cuenta, pero los templates CF son verbosos vs HCL. Sin soporte para dependencias entre stacks como Terragrunt.

**CDK (D):** potente para recursos AWS complejos (L2 constructs). Curva de aprendizaje alta. No tiene el mismo ecosistema de módulos que Terraform Registry.

**Regla del examen:** "Reutilizar Terraform sin duplicar HCL", "múltiples entornos/cuentas", "dependencias entre módulos" → **Terragrunt**.

---

## Tabla de decisión — servicios del data lake

| Necesidad | Servicio | Cuándo NO |
|---|---|---|
| Almacenar todos los datos (barato) | S3 + lifecycle → Glacier | No para queries directas sin procesar |
| Descubrir schema de archivos en S3 | Glue Crawler | No cuando schema es conocido y estable |
| ETL estándar CSV→Parquet | Glue ETL Job | No para librerías ML custom |
| ETL con librerías custom, jobs largos | EMR Serverless | No para ETL simple sin deps custom |
| SQL ad-hoc sobre S3 (poco frecuente) | Athena | No para dashboards con SLA de latencia |
| BI dashboards recurrentes | Redshift Serverless | No para queries una sola vez |
| JOIN S3 histórico + Redshift | Redshift Spectrum | No cuando todos los datos caben en Redshift |
| Búsqueda full-text, logs analytics | OpenSearch | No para SQL analítico, no reemplaza Redshift |
| Streaming datos → S3 | Firehose | No para latencia < 60s |
| Streaming tiempo real, múltiples consumers | Kinesis Data Streams | No para protocolo Kafka legacy |
| Kafka gestionado, legacy Kafka | MSK | No para ecosistema 100% AWS |
| Permisos tabla/columna/fila sobre S3 | Lake Formation | No reemplaza IAM (son complementarios) |
| IaC multi-entorno sin duplicar código | Terragrunt | No para recursos CloudFormation-nativos |
