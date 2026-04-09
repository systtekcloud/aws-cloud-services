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

# ─── S3 Bucket ───────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "data" {
  bucket        = "${var.prefix}-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = var.tags
}

# ─── IAM Role for Redshift ───────────────────────────────────────────────────

resource "aws_iam_role" "redshift" {
  name = "${var.prefix}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "redshift.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "redshift_s3" {
  name = "${var.prefix}-s3-policy"
  role = aws_iam_role.redshift.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.data.arn,
          "${aws_s3_bucket.data.arn}/*",
        ]
      },
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

# ─── Security Group for Redshift Serverless ──────────────────────────────────

resource "aws_security_group" "redshift" {
  name        = "${var.prefix}-sg"
  description = "Redshift Serverless security group"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Redshift port"
    from_port   = 5439
    to_port     = 5439
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

# ─── Redshift Serverless Namespace ───────────────────────────────────────────

resource "aws_redshiftserverless_namespace" "main" {
  namespace_name      = "${var.prefix}-namespace"
  admin_username      = var.admin_username
  admin_user_password = var.admin_password
  iam_roles           = [aws_iam_role.redshift.arn]

  tags = var.tags
}

# ─── Redshift Serverless Workgroup ───────────────────────────────────────────

resource "aws_redshiftserverless_workgroup" "main" {
  namespace_name      = aws_redshiftserverless_namespace.main.namespace_name
  workgroup_name      = "${var.prefix}-workgroup"
  base_capacity       = var.base_rpu
  publicly_accessible = var.publicly_accessible
  subnet_ids          = slice(data.aws_subnets.default.ids, 0, min(3, length(data.aws_subnets.default.ids)))
  security_group_ids  = [aws_security_group.redshift.id]

  tags = var.tags
}
