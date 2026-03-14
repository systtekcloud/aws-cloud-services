terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      Lab       = var.lab
      Env       = var.env
      ManagedBy = "terraform"
    }
  }
}

# ---------------------------------------------------------------------------
# DynamoDB Table
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "ecommerce" {
  name         = var.table_name
  billing_mode = var.billing_mode
  hash_key     = "PK"
  range_key    = "SK"

  # Solo aplica si billing_mode = PROVISIONED
  read_capacity  = var.billing_mode == "PROVISIONED" ? var.read_capacity : null
  write_capacity = var.billing_mode == "PROVISIONED" ? var.write_capacity : null

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  attribute {
    name = "GSI1PK"
    type = "S"
  }

  attribute {
    name = "GSI1SK"
    type = "S"
  }

  attribute {
    name = "GSI2PK"
    type = "S"
  }

  attribute {
    name = "GSI2SK"
    type = "S"
  }

  # GSI-1: Lookup por OrderID
  global_secondary_index {
    name            = "GSI1"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "ALL"
  }

  # GSI-2: Pedidos por Status
  global_secondary_index {
    name            = "GSI2"
    hash_key        = "GSI2PK"
    range_key       = "GSI2SK"
    projection_type = "ALL"
  }

  # TTL
  ttl {
    attribute_name = var.ttl_attribute
    enabled        = var.ttl_attribute != ""
  }

  # DynamoDB Streams
  stream_enabled   = var.enable_streams
  stream_view_type = var.enable_streams ? var.stream_view_type : null

  # Point-in-Time Recovery
  point_in_time_recovery {
    enabled = var.enable_pitr
  }
}

# ---------------------------------------------------------------------------
# Lambda para DynamoDB Streams (opcional)
# ---------------------------------------------------------------------------

data "archive_file" "lambda_zip" {
  count       = var.enable_lambda_trigger ? 1 : 0
  type        = "zip"
  output_path = "/tmp/dynamodb-stream-processor.zip"

  source {
    content  = <<-PYEOF
import json, logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    logger.info(f"Records recibidos: {len(event['Records'])}")
    for record in event['Records']:
        event_name = record['eventName']
        dynamo     = record.get('dynamodb', {})

        if event_name == 'INSERT':
            img  = dynamo.get('NewImage', {})
            pk   = img.get('PK', {}).get('S', 'N/A')
            sk   = img.get('SK', {}).get('S', 'N/A')
            tipo = img.get('tipo', {}).get('S', 'UNKNOWN')
            logger.info(f"[INSERT] PK={pk} SK={sk} tipo={tipo}")
        elif event_name == 'MODIFY':
            img = dynamo.get('NewImage', {})
            pk  = img.get('PK', {}).get('S', 'N/A')
            logger.info(f"[MODIFY] PK={pk}")
        elif event_name == 'REMOVE':
            img = dynamo.get('OldImage', {})
            pk  = img.get('PK', {}).get('S', 'N/A')
            sk  = img.get('SK', {}).get('S', 'N/A')
            logger.info(f"[REMOVE] PK={pk} SK={sk}")
    return {'statusCode': 200, 'processed': len(event['Records'])}
PYEOF
    filename = "lambda_function.py"
  }
}

data "aws_iam_policy_document" "lambda_assume" {
  count = var.enable_lambda_trigger ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  count              = var.enable_lambda_trigger ? 1 : 0
  name               = "lambda-dynamodb-stream-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume[0].json
}

resource "aws_iam_role_policy_attachment" "lambda_dynamo" {
  count      = var.enable_lambda_trigger ? 1 : 0
  role       = aws_iam_role.lambda[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaDynamoDBExecutionRole"
}

resource "aws_lambda_function" "stream_processor" {
  count = var.enable_lambda_trigger ? 1 : 0

  function_name    = var.lambda_function_name
  role             = aws_iam_role.lambda[0].arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip[0].output_path
  source_code_hash = data.archive_file.lambda_zip[0].output_base64sha256
  timeout          = 60

  depends_on = [aws_iam_role_policy_attachment.lambda_dynamo]
}

resource "aws_lambda_event_source_mapping" "dynamo_stream" {
  count = var.enable_lambda_trigger ? 1 : 0

  event_source_arn  = aws_dynamodb_table.ecommerce.stream_arn
  function_name     = aws_lambda_function.stream_processor[0].arn
  starting_position = "LATEST"
  batch_size        = 10
}

# ---------------------------------------------------------------------------
# CloudWatch Alarms
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "dynamodb-lab03-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "read_throttle" {
  alarm_name          = "dynamodb-ecommerce-read-throttle"
  alarm_description   = "DynamoDB Read Throttling detectado"
  metric_name         = "ReadThrottleEvents"
  namespace           = "AWS/DynamoDB"
  period              = 300
  evaluation_periods  = 1
  statistic           = "Sum"
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"

  dimensions = {
    TableName = aws_dynamodb_table.ecommerce.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "write_throttle" {
  alarm_name          = "dynamodb-ecommerce-write-throttle"
  alarm_description   = "DynamoDB Write Throttling detectado"
  metric_name         = "WriteThrottleEvents"
  namespace           = "AWS/DynamoDB"
  period              = 300
  evaluation_periods  = 1
  statistic           = "Sum"
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"

  dimensions = {
    TableName = aws_dynamodb_table.ecommerce.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}
