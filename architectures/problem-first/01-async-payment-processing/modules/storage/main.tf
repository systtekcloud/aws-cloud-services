variable "environment"    { type = string }
variable "enable_pitr"    { type = bool   default = false }
variable "billing_mode"   { type = string default = "PAY_PER_REQUEST" }

# Capacidad provisionada solo relevante si billing_mode = "PROVISIONED"
variable "read_capacity"  { type = number default = 5 }
variable "write_capacity" { type = number default = 5 }

# ── KMS ──────────────────────────────────────────────────────────────────────

resource "aws_kms_key" "pagos" {
  description             = "Clave KMS para pagos (${var.environment})"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = { Environment = var.environment }
}

resource "aws_kms_alias" "pagos" {
  name          = "alias/pagos-${var.environment}"
  target_key_id = aws_kms_key.pagos.key_id
}

# ── DynamoDB ─────────────────────────────────────────────────────────────────

resource "aws_dynamodb_table" "pagos" {
  name         = "pagos-${var.environment}"
  billing_mode = var.billing_mode
  hash_key     = "pago_id"

  dynamic "provisioned_throughput" {
    for_each = var.billing_mode == "PROVISIONED" ? [1] : []
    content {
      read_capacity  = var.read_capacity
      write_capacity = var.write_capacity
    }
  }

  attribute {
    name = "pago_id"
    type = "S"
  }

  attribute {
    name = "cliente_id"
    type = "S"
  }

  attribute {
    name = "fecha"
    type = "S"
  }

  global_secondary_index {
    name            = "cliente-fecha-index"
    hash_key        = "cliente_id"
    range_key       = "fecha"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ttl_expiry"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = var.enable_pitr
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.pagos.arn
  }

  tags = { Environment = var.environment }
}

# Auto-scaling (solo en PROVISIONED)
resource "aws_appautoscaling_target" "read" {
  count              = var.billing_mode == "PROVISIONED" ? 1 : 0
  max_capacity       = 100
  min_capacity       = var.read_capacity
  resource_id        = "table/${aws_dynamodb_table.pagos.name}"
  scalable_dimension = "dynamodb:table:ReadCapacityUnits"
  service_namespace  = "dynamodb"
}

resource "aws_appautoscaling_policy" "read" {
  count              = var.billing_mode == "PROVISIONED" ? 1 : 0
  name               = "pagos-read-scaling-${var.environment}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.read[0].resource_id
  scalable_dimension = aws_appautoscaling_target.read[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.read[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "DynamoDBReadCapacityUtilization"
    }
    target_value = 70
  }
}

# ── SNS ───────────────────────────────────────────────────────────────────────

resource "aws_sns_topic" "notificaciones" {
  name              = "pagos-notificaciones-${var.environment}"
  kms_master_key_id = aws_kms_key.pagos.id

  tags = { Environment = var.environment }
}

# Suscripción de ejemplo por email (en prod, se añaden FCM/APNS/webhooks)
# aws sns subscribe --topic-arn <arn> --protocol email --notification-endpoint ops@empresa.com

output "dynamodb_table_arn"  { value = aws_dynamodb_table.pagos.arn }
output "dynamodb_table_name" { value = aws_dynamodb_table.pagos.name }
output "sns_topic_arn"       { value = aws_sns_topic.notificaciones.arn }
output "kms_key_arn"         { value = aws_kms_key.pagos.arn }
