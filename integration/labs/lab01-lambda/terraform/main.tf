# integration/labs/lab01-lambda/terraform/main.tf
#
# Infraestructura completa de lab01-lambda:
#   - IAM execution role con mínimo privilegio
#   - SQS queues (trigger + DLQ)
#   - Lambda layer (dependencias Python)
#   - Lambda function principal
#   - Event Source Mapping (SQS → Lambda)
#   - Lambda Destinations (OnSuccess/OnFailure)
#   - CloudWatch Log Group con retención

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = "eu-west-1"
}

locals {
  name_prefix = "lab01-lambda"
  tags = {
    Lab     = "lab01-lambda"
    Module  = "integration"
    Managed = "terraform"
  }
}

# ─── IAM ──────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${local.name_prefix}-exec-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.tags
}

# Política básica: CloudWatch Logs
resource "aws_iam_role_policy_attachment" "basic_execution" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Política para leer de SQS (Event Source Mapping)
resource "aws_iam_role_policy_attachment" "sqs_execution" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}

# Política inline: enviar a SQS Destinations
data "aws_iam_policy_document" "destinations" {
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.success_dest.arn, aws_sqs_queue.failure_dest.arn]
  }
}

resource "aws_iam_role_policy" "destinations" {
  name   = "destinations-send"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.destinations.json
}

# ─── SQS ──────────────────────────────────────────────────────────────────────

# DLQ para el trigger queue
resource "aws_sqs_queue" "trigger_dlq" {
  name                      = "${local.name_prefix}-trigger-dlq"
  message_retention_seconds = 1209600 # 14 días
  tags                      = local.tags
}

# Queue que actúa como trigger de Lambda (Event Source Mapping)
resource "aws_sqs_queue" "trigger" {
  name                       = "${local.name_prefix}-trigger"
  visibility_timeout_seconds = 60  # >= Lambda timeout
  message_retention_seconds  = 86400
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.trigger_dlq.arn
    maxReceiveCount     = 3
  })
  tags = local.tags
}

# Queue destino para invocaciones exitosas (Destinations OnSuccess)
resource "aws_sqs_queue" "success_dest" {
  name                      = "${local.name_prefix}-success"
  message_retention_seconds = 86400
  tags                      = local.tags
}

# Queue destino para invocaciones fallidas (Destinations OnFailure)
resource "aws_sqs_queue" "failure_dest" {
  name                      = "${local.name_prefix}-failure"
  message_retention_seconds = 1209600
  tags                      = local.tags
}

# ─── LAMBDA LAYER ─────────────────────────────────────────────────────────────

# Layer con dependencias Python
# Para crear el ZIP: pip install requests -t layer/python/ && zip -r layer.zip layer/python/
resource "aws_lambda_layer_version" "deps" {
  layer_name          = "${local.name_prefix}-deps"
  description         = "Python dependencies: requests"
  filename            = "${path.module}/layer.zip"
  source_code_hash    = fileexists("${path.module}/layer.zip") ? filebase64sha256("${path.module}/layer.zip") : null
  compatible_runtimes = ["python3.12", "python3.11"]
}

# ─── LAMBDA FUNCTION ──────────────────────────────────────────────────────────

# Empaquetar el código de la función
data "archive_file" "function_zip" {
  type        = "zip"
  source_dir  = "${path.module}/src/"
  output_path = "${path.module}/function.zip"
}

resource "aws_lambda_function" "main" {
  function_name    = "${local.name_prefix}-main"
  runtime          = "python3.12"
  handler          = "handler.handler"
  role             = aws_iam_role.lambda_exec.arn
  filename         = data.archive_file.function_zip.output_path
  source_code_hash = data.archive_file.function_zip.output_base64sha256

  timeout     = 30
  memory_size = 256

  layers = [aws_lambda_layer_version.deps.arn]

  environment {
    variables = {
      ENV        = "lab"
      LOG_LEVEL  = "INFO"
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.trigger_dlq.arn
  }

  tags = local.tags
}

# Destinations: OnSuccess y OnFailure para invocaciones asíncronas
resource "aws_lambda_function_event_invoke_config" "main" {
  function_name          = aws_lambda_function.main.function_name
  maximum_retry_attempts = 1

  destination_config {
    on_success {
      destination = aws_sqs_queue.success_dest.arn
    }
    on_failure {
      destination = aws_sqs_queue.failure_dest.arn
    }
  }
}

# Event Source Mapping: SQS trigger → Lambda
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn                   = aws_sqs_queue.trigger.arn
  function_name                      = aws_lambda_function.main.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]
}

# ─── CLOUDWATCH LOGS ──────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${aws_lambda_function.main.function_name}"
  retention_in_days = 7
  tags              = local.tags
}

# Alarma: errores Lambda > 5 en 5 minutos
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name_prefix}-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Lambda errors exceeded threshold"

  dimensions = {
    FunctionName = aws_lambda_function.main.function_name
  }

  tags = local.tags
}

# Alarma: DLQ con mensajes (indica fallos no procesados)
resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  alarm_name          = "${local.name_prefix}-dlq-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Messages in DLQ — requires investigation"

  dimensions = {
    QueueName = aws_sqs_queue.trigger_dlq.name
  }

  tags = local.tags
}

# ─── OUTPUTS ──────────────────────────────────────────────────────────────────

output "function_arn" {
  value       = aws_lambda_function.main.arn
  description = "ARN de la función Lambda"
}

output "function_name" {
  value       = aws_lambda_function.main.function_name
  description = "Nombre de la función"
}

output "trigger_queue_url" {
  value       = aws_sqs_queue.trigger.url
  description = "URL de la queue trigger — envía mensajes aquí para invocar Lambda"
}

output "success_queue_url" {
  value       = aws_sqs_queue.success_dest.url
  description = "URL de la queue de éxitos (Destination OnSuccess)"
}

output "failure_queue_url" {
  value       = aws_sqs_queue.failure_dest.url
  description = "URL de la queue de fallos (Destination OnFailure)"
}

output "layer_arn" {
  value       = aws_lambda_layer_version.deps.arn
  description = "ARN del layer de dependencias"
}
