variable "environment"  { type = string }
variable "sfn_arn"      { type = string }

# ── S3 bucket (documentos entrantes) ─────────────────────────────────────────

resource "aws_s3_bucket" "documentos" {
  bucket = "docs-pipeline-${var.environment}-${data.aws_caller_identity.current.account_id}"
  tags   = { Environment = var.environment }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket_server_side_encryption_configuration" "documentos" {
  bucket = aws_s3_bucket.documentos.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Habilitar EventBridge notifications en S3
resource "aws_s3_bucket_notification" "documentos" {
  bucket      = aws_s3_bucket.documentos.id
  eventbridge = true
}

# ── IAM para EventBridge → Step Functions ────────────────────────────────────

resource "aws_iam_role" "eventbridge" {
  name = "docs-eventbridge-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge" {
  role = aws_iam_role.eventbridge.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["states:StartExecution"]
      Resource = var.sfn_arn
    }]
  })
}

# ── EventBridge Rule: S3 ObjectCreated → Step Functions ──────────────────────

resource "aws_cloudwatch_event_rule" "nuevo_documento" {
  name        = "nuevo-documento-${var.environment}"
  description = "Inicia pipeline de procesamiento cuando llega un nuevo documento"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    "detail-type" = ["Object Created"]
    detail = {
      bucket = {
        name = [aws_s3_bucket.documentos.bucket]
      }
      object = {
        key = [{ prefix = "incoming/" }]
        # Solo PDFs e imágenes de >10KB (evitar thumbnails)
        size = [{ numeric = [">", 10240] }]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "sfn" {
  rule      = aws_cloudwatch_event_rule.nuevo_documento.name
  target_id = "StartDocumentPipeline"
  arn       = var.sfn_arn
  role_arn  = aws_iam_role.eventbridge.arn

  # Transformar el evento S3 al formato que espera Step Functions
  input_transformer {
    input_paths = {
      bucket  = "$.detail.bucket.name"
      key     = "$.detail.object.key"
      size    = "$.detail.object.size"
      eventid = "$.id"
    }
    input_template = <<-JSON
    {
      "doc_id": "<eventid>",
      "bucket": "<bucket>",
      "s3_key": "<key>",
      "size_bytes": <size>
    }
    JSON
  }
}

output "bucket_arn"  { value = aws_s3_bucket.documentos.arn }
output "bucket_name" { value = aws_s3_bucket.documentos.bucket }
output "bucket_id"   { value = aws_s3_bucket.documentos.id }
