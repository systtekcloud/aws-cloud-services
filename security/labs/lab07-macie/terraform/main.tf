terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ──────────────────────────────────────────────────────────────────────────────
# Variables
# ──────────────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "create_public_bucket" {
  description = "Create a public bucket to demo Policy: findings (insecure by design)"
  type        = bool
  default     = false
}

data "aws_caller_identity" "current" {}

# ──────────────────────────────────────────────────────────────────────────────
# Macie
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_macie2_account" "main" {
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  status                       = "ENABLED"
}

# ──────────────────────────────────────────────────────────────────────────────
# S3 bucket — private (for SensitiveData: demo)
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "demo" {
  bucket        = "lab07-macie-demo-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Lab = "lab07-macie"
  }
}

resource "aws_s3_bucket_versioning" "demo" {
  bucket = aws_s3_bucket.demo.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "demo" {
  bucket = aws_s3_bucket.demo.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "demo" {
  bucket                  = aws_s3_bucket.demo.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# ──────────────────────────────────────────────────────────────────────────────
# S3 bucket — public (for Policy: findings demo) — INTENTIONALLY INSECURE
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "public_demo" {
  count         = var.create_public_bucket ? 1 : 0
  bucket        = "lab07-macie-public-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Lab     = "lab07-macie"
    Purpose = "DEMO-ONLY-intentionally-insecure"
  }
}

resource "aws_s3_bucket_public_access_block" "public_demo" {
  count  = var.create_public_bucket ? 1 : 0
  bucket = aws_s3_bucket.public_demo[0].id

  # INTENTIONALLY DISABLED for demo
  block_public_acls       = false
  ignore_public_acls      = false
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "public_demo" {
  count  = var.create_public_bucket ? 1 : 0
  bucket = aws_s3_bucket.public_demo[0].id

  # INTENTIONALLY PUBLIC for demo — generates Policy:IAMUser/S3BucketPubliclyAccessible
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject-DEMO-ONLY"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.public_demo[0].arn}/*"
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.public_demo]
}

# ──────────────────────────────────────────────────────────────────────────────
# Macie Classification Job (one-time scan)
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_macie2_classification_job" "demo" {
  job_type    = "ONE_TIME"
  name        = "lab07-demo-scan"
  description = "Lab 07 - Demo scan for sensitive data detection"

  s3_job_definition {
    bucket_definitions {
      account_id = data.aws_caller_identity.current.account_id
      buckets    = [aws_s3_bucket.demo.id]
    }
  }

  depends_on = [aws_macie2_account.main]
}

# ──────────────────────────────────────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────────────────────────────────────

output "macie_session_status" {
  value = aws_macie2_account.main.status
}

output "demo_bucket_name" {
  value = aws_s3_bucket.demo.bucket
}

output "public_bucket_name" {
  value = var.create_public_bucket ? aws_s3_bucket.public_demo[0].bucket : "not created"
}

output "classification_job_id" {
  value = aws_macie2_classification_job.demo.id
}
