variable "environment"       { type = string }
variable "vuelos_queue_url"  { type = string }
variable "hoteles_queue_url" { type = string }
variable "coches_queue_url"  { type = string }
variable "dynamodb_table_arn"  { type = string }
variable "dynamodb_table_name" { type = string }
variable "sns_topic_arn"      { type = string }

# ── IAM para Step Functions ───────────────────────────────────────────────────

resource "aws_iam_role" "sfn" {
  name = "saga-sfn-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn" {
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = "*" # en prod: ARNs específicos de las 3 colas
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = var.dynamodb_table_arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = var.sns_topic_arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogDelivery", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeResourcePolicies"]
        Resource = "*"
      }
    ]
  })
}

# ── CloudWatch Logs ───────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/saga-reservas-${var.environment}"
  retention_in_days = 90
}

# ── Step Functions — Saga Orquestada ─────────────────────────────────────────
#
# Flujo:
#   ReservarVuelo → ReservarHotel → ReservarCoche → NotificarExito
#
# Compensaciones (en fallo):
#   CancelarCoche (si procede) → CancelarHotel (si procede) → CancelarVuelo → NotificarFallo

resource "aws_sfn_state_machine" "saga_reservas" {
  name     = "saga-reservas-${var.environment}"
  role_arn = aws_iam_role.sfn.arn
  type     = "STANDARD"

  definition = jsonencode({
    Comment = "Saga orquestada: reserva de viaje (vuelo + hotel + coche)"
    StartAt = "RegistrarSagaInicio"
    States = {

      # Registro inicial en DynamoDB para auditoría
      RegistrarSagaInicio = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:putItem"
        Parameters = {
          TableName = var.dynamodb_table_name
          Item = {
            saga_id   = { "S.$" = "$$.Execution.Name" }
            status    = { S = "iniciada" }
            ts_inicio = { "S.$" = "$$.Execution.StartTime" }
            payload   = { "S.$" = "States.JsonToString($)" }
          }
        }
        ResultPath = null
        Next       = "ReservarVuelo"
      }

      ReservarVuelo = {
        Type     = "Task"
        Resource = "arn:aws:states:::sqs:sendMessage.waitForTaskToken"
        Parameters = {
          QueueUrl = var.vuelos_queue_url
          MessageBody = {
            taskToken  = { ".$" = "$$.Task.Token" }
            action     = "reservar"
            saga_id    = { ".$" = "$$.Execution.Name" }
            vuelo_id   = { ".$" = "$.vuelo_id" }
            cliente_id = { ".$" = "$.cliente_id" }
          }
        }
        HeartbeatSeconds = 30
        TimeoutSeconds   = 60
        ResultPath       = "$.vuelo_resultado"
        Next             = "ReservarHotel"
        Retry = [{
          ErrorEquals   = ["States.TaskFailed"]
          MaxAttempts   = 2
          IntervalSeconds = 5
          BackoffRate   = 2
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "NotificarFallo"
          ResultPath  = "$.error"
        }]
      }

      ReservarHotel = {
        Type     = "Task"
        Resource = "arn:aws:states:::sqs:sendMessage.waitForTaskToken"
        Parameters = {
          QueueUrl = var.hoteles_queue_url
          MessageBody = {
            taskToken  = { ".$" = "$$.Task.Token" }
            action     = "reservar"
            saga_id    = { ".$" = "$$.Execution.Name" }
            hotel_id   = { ".$" = "$.hotel_id" }
            cliente_id = { ".$" = "$.cliente_id" }
          }
        }
        HeartbeatSeconds = 30
        TimeoutSeconds   = 60
        ResultPath       = "$.hotel_resultado"
        Next             = "ReservarCoche"
        Retry = [{
          ErrorEquals   = ["States.TaskFailed"]
          MaxAttempts   = 2
          IntervalSeconds = 5
          BackoffRate   = 2
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "CancelarVuelo"
          ResultPath  = "$.error"
        }]
      }

      ReservarCoche = {
        Type     = "Task"
        Resource = "arn:aws:states:::sqs:sendMessage.waitForTaskToken"
        Parameters = {
          QueueUrl = var.coches_queue_url
          MessageBody = {
            taskToken  = { ".$" = "$$.Task.Token" }
            action     = "reservar"
            saga_id    = { ".$" = "$$.Execution.Name" }
            coche_tipo = { ".$" = "$.coche_tipo" }
            cliente_id = { ".$" = "$.cliente_id" }
          }
        }
        HeartbeatSeconds = 30
        TimeoutSeconds   = 60
        ResultPath       = "$.coche_resultado"
        Next             = "RegistrarSagaCompleta"
        Retry = [{
          ErrorEquals   = ["States.TaskFailed"]
          MaxAttempts   = 2
          IntervalSeconds = 5
          BackoffRate   = 2
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "CancelarHotel"
          ResultPath  = "$.error"
        }]
      }

      # ── Compensaciones (orden inverso) ──────────────────────────────────────

      CancelarCoche = {
        Type     = "Task"
        Resource = "arn:aws:states:::sqs:sendMessage.waitForTaskToken"
        Parameters = {
          QueueUrl = var.coches_queue_url
          MessageBody = {
            taskToken = { ".$" = "$$.Task.Token" }
            action    = "cancelar"
            saga_id   = { ".$" = "$$.Execution.Name" }
          }
        }
        HeartbeatSeconds = 30
        TimeoutSeconds   = 60
        ResultPath       = null
        Next             = "CancelarHotel"
        Retry = [{
          ErrorEquals   = ["States.ALL"]
          MaxAttempts   = 3
          IntervalSeconds = 10
          BackoffRate   = 2
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "CompensacionFallida"
          ResultPath  = "$.error_compensacion"
        }]
      }

      CancelarHotel = {
        Type     = "Task"
        Resource = "arn:aws:states:::sqs:sendMessage.waitForTaskToken"
        Parameters = {
          QueueUrl = var.hoteles_queue_url
          MessageBody = {
            taskToken = { ".$" = "$$.Task.Token" }
            action    = "cancelar"
            saga_id   = { ".$" = "$$.Execution.Name" }
          }
        }
        HeartbeatSeconds = 30
        TimeoutSeconds   = 60
        ResultPath       = null
        Next             = "CancelarVuelo"
        Retry = [{
          ErrorEquals   = ["States.ALL"]
          MaxAttempts   = 3
          IntervalSeconds = 10
          BackoffRate   = 2
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "CompensacionFallida"
          ResultPath  = "$.error_compensacion"
        }]
      }

      CancelarVuelo = {
        Type     = "Task"
        Resource = "arn:aws:states:::sqs:sendMessage.waitForTaskToken"
        Parameters = {
          QueueUrl = var.vuelos_queue_url
          MessageBody = {
            taskToken = { ".$" = "$$.Task.Token" }
            action    = "cancelar"
            saga_id   = { ".$" = "$$.Execution.Name" }
          }
        }
        HeartbeatSeconds = 30
        TimeoutSeconds   = 60
        ResultPath       = null
        Next             = "NotificarFallo"
        Retry = [{
          ErrorEquals   = ["States.ALL"]
          MaxAttempts   = 3
          IntervalSeconds = 10
          BackoffRate   = 2
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "CompensacionFallida"
          ResultPath  = "$.error_compensacion"
        }]
      }

      # ── Estados terminales ──────────────────────────────────────────────────

      RegistrarSagaCompleta = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName = var.dynamodb_table_name
          Key = {
            saga_id = { "S.$" = "$$.Execution.Name" }
          }
          UpdateExpression = "SET #s = :completada, ts_fin = :ts"
          ExpressionAttributeNames  = { "#s" = "status" }
          ExpressionAttributeValues = {
            ":completada" = { S = "completada" }
            ":ts"         = { "S.$" = "$$.State.EnteredTime" }
          }
        }
        ResultPath = null
        Next       = "NotificarExito"
      }

      NotificarExito = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = var.sns_topic_arn
          Message = {
            "Input.$" = "States.JsonToString($)"
          }
          MessageAttributes = {
            tipo = { DataType = "String", StringValue = "reserva_completada" }
          }
        }
        End = true
      }

      NotificarFallo = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = var.sns_topic_arn
          Message = {
            "Input.$" = "States.JsonToString($)"
          }
          MessageAttributes = {
            tipo = { DataType = "String", StringValue = "reserva_fallida" }
          }
        }
        Next = "SagaFallida"
      }

      SagaFallida = {
        Type  = "Fail"
        Error = "SagaCompensada"
        Cause = "Reserva cancelada — compensaciones aplicadas correctamente"
      }

      CompensacionFallida = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = var.sns_topic_arn
          Message  = "ALERTA: compensación fallida — requiere intervención manual"
          MessageAttributes = {
            tipo     = { DataType = "String", StringValue = "compensacion_fallida" }
            prioridad = { DataType = "String", StringValue = "critica" }
          }
        }
        Next = "SagaInconsistente"
      }

      SagaInconsistente = {
        Type  = "Fail"
        Error = "CompensacionFallida"
        Cause = "Saga en estado inconsistente — intervención manual requerida"
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }
}

output "sfn_arn"  { value = aws_sfn_state_machine.saga_reservas.arn }
output "sfn_name" { value = aws_sfn_state_machine.saga_reservas.name }
