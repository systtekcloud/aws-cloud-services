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

# ─── S3 Bucket for Firehose backup ───────────────────────────────────────────

resource "aws_s3_bucket" "firehose_backup" {
  bucket        = "${var.prefix}-firehose-backup-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = var.tags
}

# ─── IAM — Lambda ────────────────────────────────────────────────────────────

resource "aws_iam_role" "lambda" {
  name = "${var.prefix}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ─── IAM — Firehose ──────────────────────────────────────────────────────────

resource "aws_iam_role" "firehose" {
  name = "${var.prefix}-firehose-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "firehose_policy" {
  name = "${var.prefix}-firehose-policy"
  role = aws_iam_role.firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "es:DescribeElasticsearchDomain",
          "es:DescribeElasticsearchDomains",
          "es:DescribeElasticsearchDomainConfig",
          "es:ESHttpPost",
          "es:ESHttpPut",
        ]
        Resource = [
          aws_opensearch_domain.main.arn,
          "${aws_opensearch_domain.main.arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.firehose_backup.arn,
          "${aws_s3_bucket.firehose_backup.arn}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:PutLogEvents", "logs:CreateLogGroup", "logs:CreateLogStream"]
        Resource = "*"
      },
    ]
  })
}

# ─── IAM — CloudWatch Logs → Firehose ────────────────────────────────────────

resource "aws_iam_role" "cwlogs" {
  name = "${var.prefix}-cwlogs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "cwlogs_firehose" {
  name = "${var.prefix}-cwlogs-firehose"
  role = aws_iam_role.cwlogs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
      Resource = aws_kinesis_firehose_delivery_stream.opensearch.arn
    }]
  })
}

# ─── OpenSearch Domain ───────────────────────────────────────────────────────

resource "aws_opensearch_domain" "main" {
  domain_name    = var.domain_name
  engine_version = var.engine_version

  cluster_config {
    instance_type          = var.instance_type
    instance_count         = 1
    zone_awareness_enabled = false
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = var.volume_size_gb
  }

  encrypt_at_rest {
    enabled = true
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https = true
  }

  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = true

    master_user_options {
      master_user_name     = var.master_user_name
      master_user_password = var.master_user_password
    }
  }

  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = "es:*"
        Resource  = "arn:aws:es:${var.region}:${data.aws_caller_identity.current.account_id}:domain/${var.domain_name}/*"
        Condition = {
          IpAddress = {
            "aws:SourceIp" = var.allowed_cidr
          }
        }
      },
      {
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.firehose.arn }
        Action    = "es:*"
        Resource  = "arn:aws:es:${var.region}:${data.aws_caller_identity.current.account_id}:domain/${var.domain_name}/*"
      },
    ]
  })

  tags = var.tags
}

# ─── Kinesis Firehose → OpenSearch ───────────────────────────────────────────

resource "aws_kinesis_firehose_delivery_stream" "opensearch" {
  name        = "${var.prefix}-logs-to-opensearch"
  destination = "opensearch"

  opensearch_configuration {
    domain_arn         = aws_opensearch_domain.main.arn
    role_arn           = aws_iam_role.firehose.arn
    index_name         = "lambda-logs"
    index_rotation_period = "OneDay"

    buffering_interval = 60
    buffering_size     = 1

    retry_duration = 300

    s3_configuration {
      role_arn           = aws_iam_role.firehose.arn
      bucket_arn         = aws_s3_bucket.firehose_backup.arn
      buffering_size     = 5
      buffering_interval = 300
      compression_format = "GZIP"
    }
  }

  tags = var.tags
}
