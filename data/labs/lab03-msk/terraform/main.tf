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

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ─── Security Group ──────────────────────────────────────────────────────────

resource "aws_security_group" "msk" {
  name        = "${var.prefix}-sg"
  description = "MSK Serverless security group"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Kafka IAM (TLS)"
    from_port   = 9098
    to_port     = 9098
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

# ─── MSK Serverless Cluster ──────────────────────────────────────────────────

resource "aws_msk_serverless_cluster" "main" {
  cluster_name = "${var.prefix}-serverless"

  vpc_config {
    subnet_ids         = slice(data.aws_subnets.default.ids, 0, min(3, length(data.aws_subnets.default.ids)))
    security_group_ids = [aws_security_group.msk.id]
  }

  client_authentication {
    sasl {
      iam {
        enabled = true
      }
    }
  }

  tags = var.tags
}

# ─── S3 bucket para MSK Connect ─────────────────────────────────────────────

resource "aws_s3_bucket" "connect" {
  bucket        = "${var.prefix}-connect-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = var.tags
}

resource "aws_s3_bucket_versioning" "connect" {
  bucket = aws_s3_bucket.connect.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ─── IAM — MSK Connect ───────────────────────────────────────────────────────

resource "aws_iam_role" "msk_connect" {
  name = "${var.prefix}-connect-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "kafkaconnect.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "msk_connect" {
  name = "${var.prefix}-connect-policy"
  role = aws_iam_role.msk_connect.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:AbortMultipartUpload",
          "s3:ListBucketMultipartUploads",
          "s3:GetBucketLocation",
        ]
        Resource = [
          aws_s3_bucket.connect.arn,
          "${aws_s3_bucket.connect.arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster",
        ]
        Resource = aws_msk_serverless_cluster.main.arn
      },
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:ReadData",
          "kafka-cluster:DescribeTopic",
        ]
        Resource = "arn:aws:kafka:${var.region}:${data.aws_caller_identity.current.account_id}:topic/${var.prefix}-serverless/*"
      },
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:AlterGroup",
          "kafka-cluster:DescribeGroup",
        ]
        Resource = "arn:aws:kafka:${var.region}:${data.aws_caller_identity.current.account_id}:group/${var.prefix}-serverless/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "*"
      },
    ]
  })
}
