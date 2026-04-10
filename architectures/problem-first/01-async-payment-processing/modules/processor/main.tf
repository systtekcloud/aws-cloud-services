variable "environment"        { type = string }
variable "queue_arn"          { type = string }
variable "dynamodb_table_arn" { type = string }
variable "dynamodb_table_name"{ type = string }
variable "sns_topic_arn"      { type = string }
variable "reserved_concurrency" {
  type    = number
  default = -1 # -1 = sin límite
}

# ── IAM ──────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "lambda" {
  name = "pagos-lambda-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
        Resource = var.queue_arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query"]
        Resource = [var.dynamodb_table_arn, "${var.dynamodb_table_arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["states:StartExecution"]
        Resource = aws_sfn_state_machine.pagos.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_iam_role" "sfn" {
  name = "pagos-sfn-${var.environment}"
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
        Action   = ["lambda:InvokeFunction"]
        Resource = [aws_lambda_function.banco.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
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

# ── Lambda validador (triggered by SQS) ──────────────────────────────────────

data "archive_file" "validador" {
  type        = "zip"
  output_path = "/tmp/validador.zip"
  source {
    content  = <<-PYTHON
      import json, boto3, os, hashlib, time

      sfn = boto3.client('stepfunctions')
      ddb = boto3.client('dynamodb')

      def handler(event, context):
          results = []
          for record in event['Records']:
              body = json.loads(record['body'])
              pago_id = body['pago_id']

              # Escribir registro inicial
              try:
                  ddb.put_item(
                      TableName=os.environ['DYNAMODB_TABLE'],
                      Item={
                          'pago_id': {'S': pago_id},
                          'status':  {'S': 'validando'},
                          'ts_inicio': {'N': str(int(time.time()))}
                      },
                      ConditionExpression='attribute_not_exists(pago_id)'
                  )
              except ddb.exceptions.ConditionalCheckFailedException:
                  print(f"Pago {pago_id} ya existe, skip")
                  continue

              # Iniciar Step Functions
              sfn.start_execution(
                  stateMachineArn=os.environ['SFN_ARN'],
                  name=pago_id,
                  input=json.dumps(body)
              )

          return {'batchItemFailures': []}
    PYTHON
    filename = "handler.py"
  }
}

resource "aws_lambda_function" "validador" {
  function_name    = "pagos-validador-${var.environment}"
  role             = aws_iam_role.lambda.arn
  filename         = data.archive_file.validador.output_path
  source_code_hash = data.archive_file.validador.output_base64sha256
  runtime          = "python3.12"
  handler          = "handler.handler"
  timeout          = 30

  reserved_concurrent_executions = var.reserved_concurrency

  environment {
    variables = {
      DYNAMODB_TABLE = var.dynamodb_table_name
      SFN_ARN        = aws_sfn_state_machine.pagos.arn
    }
  }
}

resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn                   = var.queue_arn
  function_name                      = aws_lambda_function.validador.arn
  batch_size                         = 10
  function_response_types            = ["ReportBatchItemFailures"]
}

# ── Lambda banco (llamado por Step Functions) ─────────────────────────────────

data "archive_file" "banco" {
  type        = "zip"
  output_path = "/tmp/banco.zip"
  source {
    content  = <<-PYTHON
      import json, random, time

      class BancoTimeout(Exception): pass
      class BancoRechazado(Exception): pass

      def handler(event, context):
          # Simula latencia del banco (1-3s)
          time.sleep(random.uniform(1, 3))

          # Simula rechazo en 10% de casos
          if random.random() < 0.1:
              raise BancoRechazado(f"Fondos insuficientes para pago {event['pago_id']}")

          return {
              'pago_id': event['pago_id'],
              'banco_ref': f"BANCO-{random.randint(100000, 999999)}",
              'status': 'aprobado'
          }
    PYTHON
    filename = "handler.py"
  }
}

resource "aws_lambda_function" "banco" {
  function_name    = "pagos-banco-${var.environment}"
  role             = aws_iam_role.lambda.arn
  filename         = data.archive_file.banco.output_path
  source_code_hash = data.archive_file.banco.output_base64sha256
  runtime          = "python3.12"
  handler          = "handler.handler"
  timeout          = 30
}

# ── Step Functions ────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/pagos-${var.environment}"
  retention_in_days = 90
}

resource "aws_sfn_state_machine" "pagos" {
  name     = "pagos-${var.environment}"
  role_arn = aws_iam_role.sfn.arn
  type     = "STANDARD"

  definition = jsonencode({
    Comment = "Procesamiento de pagos con auditoría completa"
    StartAt = "ValidarConBanco"
    States = {
      ValidarConBanco = {
        Type     = "Task"
        Resource = aws_lambda_function.banco.arn
        Retry = [{
          ErrorEquals   = ["BancoTimeout", "Lambda.TooManyRequestsException", "Lambda.SdkClientException"]
          IntervalSeconds = 2
          MaxAttempts     = 3
          BackoffRate     = 2
          JitterStrategy  = "FULL"
        }]
        Catch = [{
          ErrorEquals = ["BancoRechazado"]
          Next        = "NotificarRechazo"
          ResultPath  = "$.error"
        }]
        Next = "RegistrarTransaccion"
      }
      RegistrarTransaccion = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:putItem"
        Parameters = {
          TableName = var.dynamodb_table_name
          Item = {
            pago_id       = { "S.$" = "$.pago_id" }
            status        = { S = "completado" }
            banco_ref     = { "S.$" = "$.banco_ref" }
            ts_completado = { "S.$" = "$$.Execution.StartTime" }
          }
          ConditionExpression         = "attribute_not_exists(#s) OR #s = :validando"
          ExpressionAttributeNames    = { "#s" = "status" }
          ExpressionAttributeValues   = { ":validando" = { S = "validando" } }
        }
        ResultPath = null
        Catch = [{
          ErrorEquals = ["DynamoDB.ConditionalCheckFailedException"]
          Next        = "NotificarCliente"
          Comment     = "Pago ya registrado (retry idempotente)"
        }]
        Next = "NotificarCliente"
      }
      NotificarCliente = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = var.sns_topic_arn
          Message = {
            "Input.$" = "States.JsonToString($)"
          }
          MessageAttributes = {
            tipo  = { DataType = "String", StringValue = "pago_completado" }
            monto = { "DataType" = "String", "StringValue.$" = "States.Format('{}', $.monto)" }
          }
        }
        End = true
      }
      NotificarRechazo = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = var.sns_topic_arn
          Message = {
            "Input.$" = "States.JsonToString($)"
          }
          MessageAttributes = {
            tipo = { DataType = "String", StringValue = "pago_rechazado" }
          }
        }
        End = true
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }
}

output "sfn_arn"          { value = aws_sfn_state_machine.pagos.arn }
output "validador_arn"    { value = aws_lambda_function.validador.arn }
