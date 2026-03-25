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

variable "create_public_s3_bucket" {
  description = "Create a public S3 bucket to generate Config NON_COMPLIANT finding"
  type        = bool
  default     = false
}

variable "create_open_sg" {
  description = "Create a Security Group with port 22 open to 0.0.0.0/0 (violates restricted-ssh)"
  type        = bool
  default     = false
}

# ──────────────────────────────────────────────────────────────────────────────
# Data sources
# ──────────────────────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

# ──────────────────────────────────────────────────────────────────────────────
# S3 bucket for Config delivery channel
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "config_delivery" {
  bucket        = "lab03-config-delivery-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Lab = "lab03-config"
  }
}

resource "aws_s3_bucket_versioning" "config_delivery" {
  bucket = aws_s3_bucket.config_delivery.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_policy" "config_delivery" {
  bucket = aws_s3_bucket.config_delivery.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSConfigBucketPermissionsCheck"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.config_delivery.arn
      },
      {
        Sid    = "AWSConfigBucketDelivery"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.config_delivery.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

# ──────────────────────────────────────────────────────────────────────────────
# IAM Role for Config Recorder
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "config_recorder" {
  name = "lab03-config-recorder-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Lab = "lab03-config"
  }
}

resource "aws_iam_role_policy_attachment" "config_recorder" {
  role       = aws_iam_role.config_recorder.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# ──────────────────────────────────────────────────────────────────────────────
# Config Recorder + Delivery Channel
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_config_configuration_recorder" "main" {
  name     = "default"
  role_arn = aws_iam_role.config_recorder.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "main" {
  name           = "default"
  s3_bucket_name = aws_s3_bucket.config_delivery.bucket

  depends_on = [aws_config_configuration_recorder.main]
}

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.main]
}

# ──────────────────────────────────────────────────────────────────────────────
# Config Rules
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_config_config_rule" "restricted_ssh" {
  name        = "restricted-ssh"
  description = "Verifica que los Security Groups no permiten puerto 22 desde 0.0.0.0/0"

  source {
    owner             = "AWS"
    source_identifier = "INCOMING_SSH_DISABLED"
  }

  scope {
    compliance_resource_types = ["AWS::EC2::SecurityGroup"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "s3_public_read_prohibited" {
  name        = "s3-bucket-public-read-prohibited"
  description = "Verifica que los buckets S3 no permiten lectura pública"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }

  scope {
    compliance_resource_types = ["AWS::S3::Bucket"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# ──────────────────────────────────────────────────────────────────────────────
# Optional: Security Group that violates restricted-ssh (for lab testing)
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_security_group" "open_ssh" {
  count = var.create_open_sg ? 1 : 0

  name        = "lab03-sg-open-ssh"
  description = "Lab03: SG con puerto 22 abierto - viola restricted-ssh"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH from anywhere (intentionally non-compliant)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Lab = "lab03-config"
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Optional: Public S3 bucket that violates s3-bucket-public-read-prohibited
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "public_test" {
  count = var.create_public_s3_bucket ? 1 : 0

  bucket        = "lab03-public-bucket-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Lab = "lab03-config"
  }
}

resource "aws_s3_bucket_public_access_block" "public_test" {
  count = var.create_public_s3_bucket ? 1 : 0

  bucket = aws_s3_bucket.public_test[0].id

  block_public_acls       = false
  ignore_public_acls      = false
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "public_test" {
  count = var.create_public_s3_bucket ? 1 : 0

  bucket = aws_s3_bucket.public_test[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.public_test[0].arn}/*"
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.public_test]
}

# ──────────────────────────────────────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────────────────────────────────────

output "config_bucket" {
  value = aws_s3_bucket.config_delivery.bucket
}

output "config_role_arn" {
  value = aws_iam_role.config_recorder.arn
}

output "non_compliant_sg_id" {
  value = var.create_open_sg ? aws_security_group.open_ssh[0].id : "not created"
}

output "public_bucket_name" {
  value = var.create_public_s3_bucket ? aws_s3_bucket.public_test[0].bucket : "not created"
}
