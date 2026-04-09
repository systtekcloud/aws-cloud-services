terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

# ─── S3 Buckets ──────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "raw" {
  bucket        = "${var.prefix}-raw-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket" "processed" {
  bucket        = "${var.prefix}-processed-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket" "results" {
  bucket        = "${var.prefix}-results-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = var.tags
}

# ─── IAM Role for Glue ───────────────────────────────────────────────────────

resource "aws_iam_role" "glue" {
  name = "${var.prefix}-glue-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3" {
  name = "${var.prefix}-glue-s3"
  role = aws_iam_role.glue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"
      ]
      Resource = [
        aws_s3_bucket.raw.arn,
        "${aws_s3_bucket.raw.arn}/*",
        aws_s3_bucket.processed.arn,
        "${aws_s3_bucket.processed.arn}/*",
      ]
    }]
  })
}

# ─── Glue Data Catalog Database ──────────────────────────────────────────────

resource "aws_glue_catalog_database" "main" {
  name        = "${replace(var.prefix, "-", "_")}_ecommerce"
  description = "Lab04 e-commerce data lake database"
}

# ─── Glue Crawler (raw CSV) ──────────────────────────────────────────────────

resource "aws_glue_crawler" "sales_raw" {
  name          = "${var.prefix}-sales-crawler"
  role          = aws_iam_role.glue.arn
  database_name = aws_glue_catalog_database.main.name

  s3_target {
    path = "s3://${aws_s3_bucket.raw.bucket}/sales/"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  tags = var.tags
}

# ─── Glue ETL Job ────────────────────────────────────────────────────────────

resource "aws_glue_job" "csv_to_parquet" {
  name         = "${var.prefix}-csv-to-parquet"
  role_arn     = aws_iam_role.glue.arn
  glue_version = "4.0"

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.raw.bucket}/scripts/glue_etl_job.py"
    python_version  = "3"
  }

  default_arguments = {
    "--source_bucket"                  = aws_s3_bucket.raw.bucket
    "--dest_bucket"                    = aws_s3_bucket.processed.bucket
    "--job-language"                   = "python"
    "--enable-continuous-cloudwatch-log" = "true"
  }

  number_of_workers = 2
  worker_type       = "G.1X"

  tags = var.tags
}

# ─── Lake Formation — registrar S3 y permisos ────────────────────────────────

resource "aws_iam_role" "lakeformation" {
  name = "${var.prefix}-lakeformation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lakeformation.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "lakeformation_s3" {
  role       = aws_iam_role.lakeformation.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_lakeformation_resource" "processed" {
  arn      = aws_s3_bucket.processed.arn
  role_arn = aws_iam_role.lakeformation.arn

  depends_on = [aws_iam_role_policy_attachment.lakeformation_s3]
}

# ─── Athena Workgroup ────────────────────────────────────────────────────────

resource "aws_athena_workgroup" "main" {
  name = "${var.prefix}-workgroup"

  configuration {
    result_configuration {
      output_location = "s3://${aws_s3_bucket.results.bucket}/athena-results/"
    }
  }

  tags = var.tags
}
