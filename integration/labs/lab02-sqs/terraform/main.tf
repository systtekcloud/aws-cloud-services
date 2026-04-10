# integration/labs/lab02-sqs/terraform/main.tf

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = "eu-west-1" }

locals {
  name_prefix = "lab02-sqs"
  tags = { Lab = "lab02-sqs", Module = "integration", Managed = "terraform" }
}

# ─── STANDARD QUEUE + DLQ ─────────────────────────────────────────────────────

resource "aws_sqs_queue" "standard_dlq" {
  name                      = "${local.name_prefix}-standard-dlq"
  message_retention_seconds = 1209600
  tags                      = local.tags
}

resource "aws_sqs_queue" "standard" {
  name                       = "${local.name_prefix}-standard"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 86400
  receive_wait_time_seconds  = 20  # Long polling

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.standard_dlq.arn
    maxReceiveCount     = 3
  })

  tags = local.tags
}

resource "aws_sqs_queue_redrive_allow_policy" "standard_dlq" {
  queue_url = aws_sqs_queue.standard_dlq.url
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.standard.arn]
  })
}

# ─── FIFO QUEUE + DLQ ─────────────────────────────────────────────────────────

resource "aws_sqs_queue" "fifo_dlq" {
  name                      = "${local.name_prefix}-fifo-dlq.fifo"
  fifo_queue                = true
  message_retention_seconds = 1209600
  tags                      = local.tags
}

resource "aws_sqs_queue" "fifo" {
  name                        = "${local.name_prefix}-fifo.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  visibility_timeout_seconds  = 60
  receive_wait_time_seconds   = 20

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.fifo_dlq.arn
    maxReceiveCount     = 3
  })

  tags = local.tags
}

# ─── CLOUDWATCH ALARMS ────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "standard_dlq_depth" {
  alarm_name          = "${local.name_prefix}-standard-dlq-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Mensajes en Standard DLQ — requiere investigación"
  dimensions          = { QueueName = aws_sqs_queue.standard_dlq.name }
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "fifo_dlq_depth" {
  alarm_name          = "${local.name_prefix}-fifo-dlq-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Mensajes en FIFO DLQ — requiere investigación"
  dimensions          = { QueueName = aws_sqs_queue.fifo_dlq.name }
  tags                = local.tags
}

# ─── OUTPUTS ──────────────────────────────────────────────────────────────────

output "standard_queue_url"  { value = aws_sqs_queue.standard.url }
output "standard_dlq_url"    { value = aws_sqs_queue.standard_dlq.url }
output "fifo_queue_url"      { value = aws_sqs_queue.fifo.url }
output "fifo_dlq_url"        { value = aws_sqs_queue.fifo_dlq.url }
