variable "environment"   { type = string }
variable "stream_arn"    { type = string }
variable "enable_pitr"   { type = bool   default = false }
variable "s3_lifecycle"  {
  type    = string
  default = "standard" # "standard" o "intelligent_tiering"
}

# ── S3 ────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "sensors" {
  bucket = "iot-sensors-${var.environment}-${data.aws_caller_identity.current.account_id}"

  tags = { Environment = var.environment }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket_versioning" "sensors" {
  bucket = aws_s3_bucket.sensors.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "sensors" {
  bucket = aws_s3_bucket.sensors.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "sensors" {
  bucket = aws_s3_bucket.sensors.id

  rule {
    id     = "sensor-lifecycle"
    status = "Enabled"

    filter { prefix = "sensors/" }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = 730 # 2 años retención
    }
  }
}

# ── IAM para Firehose ─────────────────────────────────────────────────────────

resource "aws_iam_role" "firehose" {
  name = "iot-firehose-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "firehose" {
  role = aws_iam_role.firehose.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.sensors.arn, "${aws_s3_bucket.sensors.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["glue:GetTable", "glue:GetTableVersion", "glue:GetTableVersions"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# ── Kinesis Data Firehose ─────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/firehose/sensors-${var.environment}"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_stream" "firehose_s3" {
  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

resource "aws_kinesis_firehose_delivery_stream" "sensors" {
  name        = "sensors-${var.environment}"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = aws_s3_bucket.sensors.arn

    prefix              = "sensors/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "errors/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/!{firehose:error-output-type}/"

    buffering_size     = 128  # MB
    buffering_interval = 300  # segundos (5 min)

    compression_format = "UNCOMPRESSED" # Parquet tiene su propia compresión

    data_format_conversion_configuration {
      enabled = true

      input_format_configuration {
        deserializer {
          open_x_json_ser_de {}
        }
      }

      output_format_configuration {
        serializer {
          parquet_ser_de {
            compression = "SNAPPY"
          }
        }
      }

      schema_configuration {
        role_arn      = aws_iam_role.firehose.arn
        database_name = aws_glue_catalog_database.sensors.name
        table_name    = aws_glue_catalog_table.telemetry.name
        region        = data.aws_region.current.name
      }
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose_s3.name
    }
  }

  tags = { Environment = var.environment }
}

data "aws_region" "current" {}

# ── AWS Glue Catalog ──────────────────────────────────────────────────────────

resource "aws_glue_catalog_database" "sensors" {
  name = "iot_sensors_${var.environment}"
}

resource "aws_glue_catalog_table" "telemetry" {
  name          = "telemetry"
  database_name = aws_glue_catalog_database.sensors.name

  table_type = "EXTERNAL_TABLE"

  parameters = {
    "classification"  = "parquet"
    "EXTERNAL"        = "TRUE"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.sensors.bucket}/sensors/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters = {
        "serialization.format" = "1"
      }
    }

    columns {
      name = "device_id"
      type = "string"
    }
    columns {
      name = "zone_id"
      type = "string"
    }
    columns {
      name = "plant_id"
      type = "string"
    }
    columns {
      name = "temp"
      type = "double"
    }
    columns {
      name = "pressure"
      type = "double"
    }
    columns {
      name = "humidity"
      type = "double"
    }
    columns {
      name = "ts"
      type = "bigint"
    }
    columns {
      name = "ingested_at"
      type = "bigint"
    }
  }

  partition_keys {
    name = "year"
    type = "string"
  }
  partition_keys {
    name = "month"
    type = "string"
  }
  partition_keys {
    name = "day"
    type = "string"
  }
}

# ── DynamoDB (últimas lecturas en tiempo real) ────────────────────────────────

resource "aws_dynamodb_table" "sensors" {
  name         = "iot-sensors-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "device_id"

  attribute {
    name = "device_id"
    type = "S"
  }

  attribute {
    name = "zone_id"
    type = "S"
  }

  global_secondary_index {
    name            = "zone-index"
    hash_key        = "zone_id"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = var.enable_pitr
  }

  tags = { Environment = var.environment }
}

# ── SNS (alertas) ─────────────────────────────────────────────────────────────

resource "aws_sns_topic" "alerts" {
  name = "iot-alerts-${var.environment}"

  tags = { Environment = var.environment }
}

output "s3_bucket_id"       { value = aws_s3_bucket.sensors.id }
output "s3_bucket_arn"      { value = aws_s3_bucket.sensors.arn }
output "firehose_arn"       { value = aws_kinesis_firehose_delivery_stream.sensors.arn }
output "dynamodb_table_arn" { value = aws_dynamodb_table.sensors.arn }
output "dynamodb_table_name"{ value = aws_dynamodb_table.sensors.name }
output "sns_topic_arn"      { value = aws_sns_topic.alerts.arn }
output "glue_database"      { value = aws_glue_catalog_database.sensors.name }
