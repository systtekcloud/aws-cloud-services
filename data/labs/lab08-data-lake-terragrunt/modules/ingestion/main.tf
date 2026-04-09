# modules/ingestion/main.tf
#
# Capa de ingesta:
#   Kinesis Data Stream → Firehose → S3 raw/
#
# El KDS actúa como buffer de tiempo real. Firehose lee del KDS,
# agrupa eventos en batches y los escribe en S3 con prefijo raw/year/month/day/

# ─── Kinesis Data Stream ──────────────────────────────────────────────────────

resource "aws_kinesis_stream" "events" {
  name             = "${var.name_prefix}-events"
  shard_count      = var.kds_shard_count
  retention_period = 24 # horas; 7 días máximo en PROVISIONED

  stream_mode_details {
    stream_mode = "PROVISIONED"
    # Para producción: ON_DEMAND elimina la gestión de shards
  }

  tags = merge(var.common_tags, { Name = "${var.name_prefix}-events" })
}

# ─── IAM Role para Firehose ───────────────────────────────────────────────────

resource "aws_iam_role" "firehose" {
  name = "${var.name_prefix}-firehose-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "sts:ExternalId" = var.account_id }
      }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "firehose" {
  name = "firehose-kds-s3"
  role = aws_iam_role.firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Leer del Kinesis Data Stream
        Effect = "Allow"
        Action = [
          "kinesis:GetRecords", "kinesis:GetShardIterator",
          "kinesis:DescribeStream", "kinesis:ListShards",
          "kinesis:SubscribeToShard"
        ]
        Resource = aws_kinesis_stream.events.arn
      },
      {
        # Escribir en S3
        Effect = "Allow"
        Action = [
          "s3:PutObject", "s3:GetObject", "s3:ListBucket",
          "s3:GetBucketLocation", "s3:AbortMultipartUpload",
          "s3:ListBucketMultipartUploads"
        ]
        Resource = [
          var.data_lake_bucket_arn,
          "${var.data_lake_bucket_arn}/*"
        ]
      }
    ]
  })
}

# ─── Kinesis Firehose → S3 raw/ ───────────────────────────────────────────────

resource "aws_kinesis_firehose_delivery_stream" "raw" {
  name        = "${var.name_prefix}-raw-delivery"
  destination = "extended_s3"

  # Fuente: Kinesis Data Stream (no HTTP endpoint ni direct PUT)
  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.events.arn
    role_arn           = aws_iam_role.firehose.arn
  }

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = var.data_lake_bucket_arn

    # Prefijo con partición temporal — facilita queries Athena por fecha
    prefix              = "raw/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/"
    error_output_prefix = "raw-errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"

    buffering_size     = var.firehose_buffer_mb
    buffering_interval = var.firehose_buffer_seconds

    compression_format = "GZIP" # Ahorra ~70% de espacio en S3

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = "/aws/kinesisfirehose/${var.name_prefix}-raw-delivery"
      log_stream_name = "S3Delivery"
    }
  }

  tags = merge(var.common_tags, { Name = "${var.name_prefix}-raw-delivery" })
}
