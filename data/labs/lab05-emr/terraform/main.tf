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

resource "aws_s3_bucket" "input" {
  bucket        = "${var.prefix}-input-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket" "output" {
  bucket        = "${var.prefix}-output-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket" "logs" {
  bucket        = "${var.prefix}-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = var.tags
}

# ─── IAM Role for EMR Serverless ─────────────────────────────────────────────

resource "aws_iam_role" "emr_serverless" {
  name = "${var.prefix}-serverless-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "emr-serverless.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "emr_s3" {
  name = "${var.prefix}-s3-policy"
  role = aws_iam_role.emr_serverless.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.input.arn,
          "${aws_s3_bucket.input.arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.output.arn,
          "${aws_s3_bucket.output.arn}/*",
          aws_s3_bucket.logs.arn,
          "${aws_s3_bucket.logs.arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
        ]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/emr-serverless/*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "emr_glue" {
  name = "${var.prefix}-glue-policy"
  role = aws_iam_role.emr_serverless.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartitions",
          "glue:GetPartition",
          "glue:BatchGetPartition",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["lakeformation:GetDataAccess"]
        Resource = "*"
      },
    ]
  })
}

# ─── EMR Serverless Application ──────────────────────────────────────────────

resource "aws_emrserverless_application" "spark" {
  name          = "${var.prefix}-spark-app"
  release_label = var.emr_release_label
  type          = "SPARK"

  maximum_capacity {
    cpu    = "8 vCPU"
    memory = "16 GB"
  }

  tags = var.tags
}
