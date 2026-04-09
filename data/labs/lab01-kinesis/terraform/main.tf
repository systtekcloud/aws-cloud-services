terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

# ─── KDS ────────────────────────────────────────────────────────────────────

resource "aws_kinesis_stream" "main" {
  name             = "${var.prefix}-kds"
  shard_count      = var.shard_count
  retention_period = var.retention_hours

  shard_level_metrics = [
    "IncomingBytes",
    "OutgoingBytes",
    "IncomingRecords",
    "IteratorAgeMilliseconds",
  ]

  tags = var.tags
}

# ─── S3 bucket destino Firehose ──────────────────────────────────────────────

resource "aws_s3_bucket" "firehose" {
  bucket        = "${var.prefix}-firehose-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = var.tags
}

resource "aws_s3_bucket_versioning" "firehose" {
  bucket = aws_s3_bucket.firehose.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "firehose" {
  bucket = aws_s3_bucket.firehose.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "firehose" {
  bucket                  = aws_s3_bucket.firehose.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
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

resource "aws_iam_role_policy" "firehose" {
  name = "${var.prefix}-firehose-policy"
  role = aws_iam_role.firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = [
          aws_s3_bucket.firehose.arn,
          "${aws_s3_bucket.firehose.arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kinesis:GetRecords",
          "kinesis:GetShardIterator",
          "kinesis:DescribeStream",
          "kinesis:ListShards",
        ]
        Resource = aws_kinesis_stream.main.arn
      },
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction",
          "lambda:GetFunctionConfiguration",
        ]
        Resource = aws_lambda_function.transform.arn
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

# ─── Lambda — transformación Firehose ────────────────────────────────────────

data "archive_file" "transform" {
  type        = "zip"
  output_path = "${path.module}/transform.zip"

  source {
    content  = <<-PYTHON
      import json
      import base64

      def handler(event, context):
          output = []
          for record in event['records']:
              payload = json.loads(base64.b64decode(record['data']))
              payload['processed'] = True
              payload['env'] = '${var.prefix}'
              transformed = json.dumps(payload) + '\n'
              output.append({
                  'recordId': record['recordId'],
                  'result': 'Ok',
                  'data': base64.b64encode(transformed.encode()).decode()
              })
          return {'records': output}
      PYTHON
    filename = "transform.py"
  }
}

resource "aws_lambda_function" "transform" {
  function_name    = "${var.prefix}-firehose-transform"
  role             = aws_iam_role.lambda.arn
  handler          = "transform.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.transform.output_path
  source_code_hash = data.archive_file.transform.output_base64sha256
  timeout          = 60

  tags = var.tags
}

# ─── Firehose: KDS → S3 con transformación Lambda ────────────────────────────

resource "aws_kinesis_firehose_delivery_stream" "main" {
  name        = "${var.prefix}-firehose"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.main.arn
    role_arn           = aws_iam_role.firehose.arn
  }

  extended_s3_configuration {
    role_arn           = aws_iam_role.firehose.arn
    bucket_arn         = aws_s3_bucket.firehose.arn
    buffering_size     = 1
    buffering_interval = 60
    compression_format = "GZIP"

    prefix              = "data/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "errors/year=!{timestamp:yyyy}/month=!{timestamp:MM}/!{firehose:error-output-type}/"

    processing_configuration {
      enabled = true

      processors {
        type = "Lambda"
        parameters {
          parameter_name  = "LambdaArn"
          parameter_value = aws_lambda_function.transform.arn
        }
      }
    }
  }

  tags = var.tags
}
