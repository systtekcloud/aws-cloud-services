# security/labs/lab02-access-analyzer/terraform/main.tf
#
# Recursos Terraform para el lab02-access-analyzer.
# Crea el analyzer + recursos de prueba (S3 bucket e IAM Role)
# con configuraciones parametrizables para experimentar con findings.

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Lab       = "lab02-access-analyzer"
      ManagedBy = "Terraform"
    }
  }
}

# ─── Variables ──────────────────────────────────────────

variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "external_account_id" {
  type        = string
  description = "ID de cuenta AWS externa para simular acceso cross-account en los recursos de prueba."
  default     = "111122223333"
}

variable "create_public_bucket" {
  type        = bool
  default     = false
  description = "Si true, crea un bucket S3 con policy pública para generar finding isPublic=true."
}

variable "create_cross_account_role" {
  type        = bool
  default     = false
  description = "Si true, crea un IAM Role con trust policy cross-account para generar finding de rol."
}

# ─── Data sources ────────────────────────────────────────

data "aws_caller_identity" "current" {}

# ─── IAM Access Analyzer ─────────────────────────────────

resource "aws_accessanalyzer_analyzer" "this" {
  analyzer_name = "lab02-account-analyzer"
  type          = "ACCOUNT"
  # type = "ORGANIZATION" requiere AWS Organizations habilitado
}

# ─── S3 Bucket cross-account ─────────────────────────────

resource "aws_s3_bucket" "cross_account" {
  bucket = "lab02-access-analyzer-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_policy" "cross_account" {
  bucket = aws_s3_bucket.cross_account.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CrossAccountRead"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.external_account_id}:root"
        }
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.cross_account.arn,
          "${aws_s3_bucket.cross_account.arn}/*"
        ]
      }
    ]
  })
}

# ─── S3 Bucket público (opcional) ────────────────────────

resource "aws_s3_bucket" "public" {
  count  = var.create_public_bucket ? 1 : 0
  bucket = "lab02-public-test-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "public" {
  count  = var.create_public_bucket ? 1 : 0
  bucket = aws_s3_bucket.public[0].id

  block_public_acls       = false
  ignore_public_acls      = false
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "public" {
  count  = var.create_public_bucket ? 1 : 0
  bucket = aws_s3_bucket.public[0].id

  # Depende de que el public access block esté configurado primero
  depends_on = [aws_s3_bucket_public_access_block.public]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicRead"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.public[0].arn}/*"
      }
    ]
  })
}

# ─── IAM Role cross-account (opcional) ───────────────────

resource "aws_iam_role" "cross_account" {
  count = var.create_cross_account_role ? 1 : 0
  name  = "lab02-cross-account-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.external_account_id}:root"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  description = "Lab02: rol de prueba con trust policy cross-account"
}

# ─── Outputs ─────────────────────────────────────────────

output "analyzer_arn" {
  value       = aws_accessanalyzer_analyzer.this.arn
  description = "ARN del IAM Access Analyzer"
}

output "cross_account_bucket_arn" {
  value       = aws_s3_bucket.cross_account.arn
  description = "ARN del bucket S3 con acceso cross-account (genera finding)"
}

output "public_bucket_arn" {
  value       = var.create_public_bucket ? aws_s3_bucket.public[0].arn : null
  description = "ARN del bucket S3 público (genera finding isPublic=true)"
}

output "cross_account_role_arn" {
  value       = var.create_cross_account_role ? aws_iam_role.cross_account[0].arn : null
  description = "ARN del IAM Role con trust policy cross-account (genera finding)"
}
