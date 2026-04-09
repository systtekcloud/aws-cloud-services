# modules/processing/main.tf
#
# Capa de procesamiento:
#   Glue Crawler → descubre schemas en raw/
#   Glue ETL Job → raw/ (CSV/JSON) → processed/ (Parquet, comprimido Snappy)
#   EMR Serverless → jobs Spark complejos sobre processed/

# ─── Glue Crawler (descubrimiento de schema en raw/) ─────────────────────────

resource "aws_glue_crawler" "raw" {
  name          = "${var.name_prefix}-raw-crawler"
  role          = var.glue_role_arn
  database_name = var.glue_database_name
  description   = "Crawler para descubrir schemas en la zona raw/ del data lake"

  s3_target {
    path = "s3://${var.data_lake_bucket_id}/raw/"
  }

  # Agrupación de tablas: una tabla por prefijo de "carpeta"
  configuration = jsonencode({
    Version = 1.0
    Grouping = {
      TableGroupingPolicy     = "CombineCompatibleSchemas"
      TableLevelConfiguration = 3 # raw/year/month → tabla en catalog
    }
  })

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  tags = var.common_tags
}

# ─── Script PySpark para el ETL Job ───────────────────────────────────────────
# El script se sube al bucket S3 (zona scripts/)

resource "aws_s3_object" "etl_script" {
  bucket = var.data_lake_bucket_id
  key    = "scripts/etl_raw_to_processed.py"

  content = <<-PYTHON
    # etl_raw_to_processed.py
    # Glue ETL Job: raw/ (JSON/CSV) → processed/ (Parquet + Snappy)
    # Particionado por year/month/day para optimizar queries Athena

    import sys
    from awsglue.transforms import *
    from awsglue.utils import getResolvedOptions
    from pyspark.context import SparkContext
    from awsglue.context import GlueContext
    from awsglue.job import Job
    from awsglue.dynamicframe import DynamicFrame

    args = getResolvedOptions(sys.argv, ['JOB_NAME', 'SOURCE_PATH', 'TARGET_PATH', 'DATABASE', 'TABLE'])

    sc = SparkContext()
    glueContext = GlueContext(sc)
    spark = glueContext.spark_session
    job = Job(glueContext)
    job.init(args['JOB_NAME'], args)

    # Leer desde el Glue Catalog (tabla descubierta por el Crawler)
    datasource = glueContext.create_dynamic_frame.from_catalog(
        database=args['DATABASE'],
        table_name=args['TABLE'],
        transformation_ctx="datasource"
    )

    print(f"Schema raw: {datasource.schema()}")
    print(f"Registros leídos: {datasource.count()}")

    # Normalizar tipos: evitar ambigüedades de tipo entre JSON y Parquet
    mapped = ApplyMapping.apply(
        frame=datasource,
        mappings=[
            # Ajustar según el schema real descubierto por el Crawler
            ("event_id",   "string", "event_id",   "string"),
            ("timestamp",  "string", "event_time", "timestamp"),
            ("user_id",    "string", "user_id",    "string"),
            ("event_type", "string", "event_type", "string"),
            ("payload",    "string", "payload",    "string"),
        ],
        transformation_ctx="mapped"
    )

    # Convertir a Spark DataFrame para añadir columnas de partición
    df = mapped.toDF()
    from pyspark.sql.functions import year, month, dayofmonth, col, to_timestamp

    df = df.withColumn("year",  year(col("event_time"))) \
           .withColumn("month", month(col("event_time"))) \
           .withColumn("day",   dayofmonth(col("event_time")))

    # Convertir de vuelta a DynamicFrame para el sink de Glue
    processed = DynamicFrame.fromDF(df, glueContext, "processed")

    # Escribir en processed/ con particionado y formato Parquet Snappy
    glueContext.write_dynamic_frame.from_options(
        frame=processed,
        connection_type="s3",
        connection_options={
            "path": args['TARGET_PATH'],
            "partitionKeys": ["year", "month", "day"]
        },
        format="parquet",
        format_options={"compression": "snappy"},
        transformation_ctx="sink"
    )

    print(f"ETL completado. Datos escritos en: {args['TARGET_PATH']}")
    job.commit()
  PYTHON

  tags = var.common_tags
}

# ─── Glue ETL Job ────────────────────────────────────────────────────────────

resource "aws_glue_job" "raw_to_processed" {
  name         = "${var.name_prefix}-raw-to-processed"
  role_arn     = var.glue_role_arn
  description  = "ETL: raw/ (JSON/CSV) → processed/ (Parquet Snappy, particionado)"
  glue_version = "4.0"

  command {
    name            = "glueetl"
    script_location = "s3://${var.data_lake_bucket_id}/scripts/etl_raw_to_processed.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-spark-ui"                  = "true"
    "--spark-event-logs-path"            = "s3://${var.data_lake_bucket_id}/spark-logs/"
    "--SOURCE_PATH"                      = "s3://${var.data_lake_bucket_id}/raw/"
    "--TARGET_PATH"                      = "s3://${var.data_lake_bucket_id}/processed/"
    "--DATABASE"                         = var.glue_database_name
    "--TABLE"                            = "raw"
    "--TempDir"                          = "s3://${var.data_lake_bucket_id}/glue-temp/"
  }

  worker_type       = var.glue_worker_type
  number_of_workers = var.glue_num_workers
  timeout           = 60 # minutos

  # Reintentos automáticos en caso de fallo transitorio
  max_retries = 1

  tags = var.common_tags

  depends_on = [aws_s3_object.etl_script]
}

# ─── EMR Serverless Application ──────────────────────────────────────────────

resource "aws_iam_role" "emr_serverless" {
  name = "${var.name_prefix}-emr-serverless-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "emr-serverless.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "emr_serverless" {
  name = "emr-s3-glue-access"
  role = aws_iam_role.emr_serverless.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
          "s3:ListBucket", "s3:GetBucketLocation"
        ]
        Resource = [
          var.data_lake_bucket_arn,
          "${var.data_lake_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "glue:GetDatabase", "glue:GetDatabases",
          "glue:GetTable", "glue:GetTables",
          "glue:GetPartition", "glue:GetPartitions",
          "glue:CreateTable", "glue:UpdateTable",
          "glue:BatchCreatePartition", "glue:BatchGetPartition"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["lakeformation:GetDataAccess"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_emrserverless_application" "spark" {
  name          = "${var.name_prefix}-spark"
  release_label = "emr-7.0.0"
  type          = "SPARK"

  maximum_capacity {
    cpu    = var.emr_cpu_max
    memory = var.emr_memory_max
  }

  # Pre-inicializar workers para reducir cold start (~2 min → ~10 seg)
  initial_capacity {
    initial_capacity_type = "Driver"
    initial_capacity_config {
      worker_count = 1
      worker_configuration {
        cpu    = "2 vCPU"
        memory = "4 GB"
      }
    }
  }

  # Auto-stop tras 15 minutos de inactividad (ahorra costes)
  auto_stop_configuration {
    enabled              = true
    idle_timeout_minutes = 15
  }

  tags = merge(var.common_tags, { Name = "${var.name_prefix}-spark" })
}
