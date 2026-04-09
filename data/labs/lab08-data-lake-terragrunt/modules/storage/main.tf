# modules/storage/main.tf
#
# S3 Data Lake — tres zonas:
#   raw/       → datos sin procesar (CSV, JSON, Avro)
#   processed/ → datos transformados (Parquet, particionados por fecha)
#   curated/   → datos agregados listos para BI / Redshift

# ─── Bucket principal del data lake ──────────────────────────────────────────

resource "aws_s3_bucket" "data_lake" {
  bucket        = "${var.name_prefix}-data-lake"
  force_destroy = true # Lab: permite destroy aunque tenga datos

  tags = merge(var.common_tags, { Name = "${var.name_prefix}-data-lake" })
}

resource "aws_s3_bucket_versioning" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true # Reduce costes de llamadas KMS en ~99%
  }
}

resource "aws_s3_bucket_public_access_block" "data_lake" {
  bucket                  = aws_s3_bucket.data_lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle: raw/ → Glacier IR a los 90 días; curated/ expira a los 365 días
resource "aws_s3_bucket_lifecycle_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  rule {
    id     = "raw-to-glacier"
    status = "Enabled"
    filter { prefix = "raw/" }
    transition {
      days          = var.lifecycle_transition_days
      storage_class = "GLACIER_IR"
    }
  }

  rule {
    id     = "curated-expiration"
    status = "Enabled"
    filter { prefix = "curated/" }
    expiration {
      days = var.lifecycle_expiration_days
    }
  }
}

# ─── Bucket de logs de acceso (separado por buenas prácticas) ────────────────

resource "aws_s3_bucket" "access_logs" {
  bucket        = "${var.name_prefix}-access-logs"
  force_destroy = true

  tags = merge(var.common_tags, { Name = "${var.name_prefix}-access-logs" })
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "data_lake" {
  bucket        = aws_s3_bucket.data_lake.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "s3-access-logs/"
}

# ─── Prefijos iniciales (objetos "carpeta" para que existan las zonas) ────────
# S3 no tiene carpetas reales, pero Athena y los crawlers
# esperan ver prefijos al menos vacíos en algunos casos.

resource "aws_s3_object" "raw_prefix" {
  bucket  = aws_s3_bucket.data_lake.id
  key     = "raw/.keep"
  content = ""
}

resource "aws_s3_object" "processed_prefix" {
  bucket  = aws_s3_bucket.data_lake.id
  key     = "processed/.keep"
  content = ""
}

resource "aws_s3_object" "curated_prefix" {
  bucket  = aws_s3_bucket.data_lake.id
  key     = "curated/.keep"
  content = ""
}

# ─── Scripts de Glue / Spark ──────────────────────────────────────────────────

resource "aws_s3_object" "glue_scripts_prefix" {
  bucket  = aws_s3_bucket.data_lake.id
  key     = "scripts/.keep"
  content = ""
}
