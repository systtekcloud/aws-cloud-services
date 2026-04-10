variable "environment" { type = string }

resource "aws_dynamodb_table" "sagas" {
  name         = "sagas-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "saga_id"

  attribute {
    name = "saga_id"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
    projection_type = "ALL"
  }

  # Para detectar sagas en estado inconsistente que llevan mucho tiempo
  ttl {
    attribute_name = "ttl_expiry"
    enabled        = true
  }

  tags = { Environment = var.environment }
}

resource "aws_sns_topic" "reservas" {
  name = "saga-reservas-${var.environment}"
  tags = { Environment = var.environment }
}

output "dynamodb_table_arn"  { value = aws_dynamodb_table.sagas.arn }
output "dynamodb_table_name" { value = aws_dynamodb_table.sagas.name }
output "sns_topic_arn"       { value = aws_sns_topic.reservas.arn }
