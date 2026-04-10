variable "environment" { type = string }
variable "dlq_alarm_arn" { type = string }

resource "aws_sqs_queue" "dlq" {
  name                      = "pagos-dlq-${var.environment}.fifo"
  fifo_queue                = true
  content_based_deduplication = true
  message_retention_seconds = 1209600 # 14 días

  tags = { Environment = var.environment }
}

resource "aws_sqs_queue" "pagos" {
  name                       = "pagos-${var.environment}.fifo"
  fifo_queue                 = true
  content_based_deduplication = false # deduplication ID explícito

  visibility_timeout_seconds = 90   # > Lambda timeout (30s) × MaxAttempts (3)
  message_retention_seconds  = 86400 # 24h — mensajes no procesados van al DLQ

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })

  tags = { Environment = var.environment }
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "pagos-dlq-not-empty-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Pagos en DLQ — requiere intervención manual"
  alarm_actions       = [var.dlq_alarm_arn]

  dimensions = {
    QueueName = aws_sqs_queue.dlq.name
  }
}

output "queue_arn" { value = aws_sqs_queue.pagos.arn }
output "queue_url" { value = aws_sqs_queue.pagos.id }
output "dlq_arn"   { value = aws_sqs_queue.dlq.arn }
