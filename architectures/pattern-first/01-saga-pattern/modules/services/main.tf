variable "environment" { type = string }

# ── SQS queues (una por servicio) ─────────────────────────────────────────────

locals {
  servicios = ["vuelos", "hoteles", "coches"]
}

resource "aws_sqs_queue" "servicios" {
  for_each = toset(local.servicios)

  name                       = "saga-${each.key}-${var.environment}"
  visibility_timeout_seconds = 90
  message_retention_seconds  = 86400

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 3
  })

  tags = { Environment = var.environment, Servicio = each.key }
}

resource "aws_sqs_queue" "dlq" {
  for_each = toset(local.servicios)

  name                      = "saga-${each.key}-dlq-${var.environment}"
  message_retention_seconds = 1209600 # 14 días

  tags = { Environment = var.environment }
}

# ── IAM para Lambdas mock ─────────────────────────────────────────────────────

resource "aws_iam_role" "lambda_mock" {
  name = "saga-lambda-mock-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_mock" {
  role = aws_iam_role.lambda_mock.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = [for q in aws_sqs_queue.servicios : q.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["states:SendTaskSuccess", "states:SendTaskFailure"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# ── Lambda mock genérica (simula cada microservicio) ──────────────────────────
#
# En prod, cada servicio (vuelos, hoteles, coches) sería un ECS Fargate
# que lee de su cola SQS y llama a SendTaskSuccess/SendTaskFailure.
# En este lab, una Lambda mock simula el comportamiento.

data "archive_file" "mock" {
  type        = "zip"
  output_path = "/tmp/saga-mock.zip"
  source {
    content  = <<-PYTHON
      import json, boto3, random, os

      sfn = boto3.client('stepfunctions')

      def handler(event, context):
          for record in event['Records']:
              body = json.loads(record['body'])
              task_token = body['taskToken']
              action     = body['action']
              saga_id    = body['saga_id']
              servicio   = os.environ['SERVICIO']

              print(f"[{servicio}] {action} para saga {saga_id}")

              # Simula fallo en 15% de reservas (no en cancelaciones)
              if action == 'reservar' and random.random() < 0.15:
                  sfn.send_task_failure(
                      taskToken=task_token,
                      error='NoDisponible',
                      cause=f'{servicio} no disponible para las fechas solicitadas'
                  )
              else:
                  # Éxito
                  resultado = {
                      'servicio':   servicio,
                      'accion':     action,
                      'referencia': f'{servicio.upper()}-{random.randint(10000, 99999)}',
                      'status':     'completado' if action == 'reservar' else 'cancelado'
                  }
                  sfn.send_task_success(
                      taskToken=task_token,
                      output=json.dumps(resultado)
                  )
    PYTHON
    filename = "handler.py"
  }
}

resource "aws_lambda_function" "mock" {
  for_each = toset(local.servicios)

  function_name    = "saga-mock-${each.key}-${var.environment}"
  role             = aws_iam_role.lambda_mock.arn
  filename         = data.archive_file.mock.output_path
  source_code_hash = data.archive_file.mock.output_base64sha256
  runtime          = "python3.12"
  handler          = "handler.handler"
  timeout          = 30

  environment {
    variables = {
      SERVICIO = each.key
    }
  }
}

resource "aws_lambda_event_source_mapping" "mock" {
  for_each = toset(local.servicios)

  event_source_arn = aws_sqs_queue.servicios[each.key].arn
  function_name    = aws_lambda_function.mock[each.key].arn
  batch_size       = 1 # Procesar de a uno (saga espera respuesta antes del siguiente)
}

output "vuelos_queue_url"  { value = aws_sqs_queue.servicios["vuelos"].id }
output "hoteles_queue_url" { value = aws_sqs_queue.servicios["hoteles"].id }
output "coches_queue_url"  { value = aws_sqs_queue.servicios["coches"].id }
output "vuelos_queue_arn"  { value = aws_sqs_queue.servicios["vuelos"].arn }
output "hoteles_queue_arn" { value = aws_sqs_queue.servicios["hoteles"].arn }
output "coches_queue_arn"  { value = aws_sqs_queue.servicios["coches"].arn }
