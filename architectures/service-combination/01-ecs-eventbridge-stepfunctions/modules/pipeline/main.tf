variable "environment"        { type = string }
variable "ecs_cluster_arn"    { type = string }
variable "ecs_cluster_name"   { type = string }
variable "ecr_repository_url" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "fargate_sg_id"      { type = string }
variable "dynamodb_table_name"{ type = string }
variable "dynamodb_table_arn" { type = string }
variable "docs_bucket_arn"    { type = string }
variable "docs_bucket_name"   { type = string }

# ── IAM para ECS Task ─────────────────────────────────────────────────────────

resource "aws_iam_role" "ecs_task_execution" {
  name = "docs-ecs-execution-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task" {
  name = "docs-ecs-task-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ecs_task" {
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${var.docs_bucket_arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = var.dynamodb_table_arn
      },
      {
        Effect   = "Allow"
        Action   = ["states:SendTaskSuccess", "states:SendTaskFailure", "states:SendTaskHeartbeat"]
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

# ── IAM para Step Functions ───────────────────────────────────────────────────

resource "aws_iam_role" "sfn" {
  name = "docs-sfn-${var.environment}"
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
        Action   = ["ecs:RunTask"]
        Resource = [aws_ecs_task_definition.ocr.arn, aws_ecs_task_definition.extractor.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [aws_iam_role.ecs_task_execution.arn, aws_iam_role.ecs_task.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [aws_lambda_function.validator.arn, aws_lambda_function.registrar.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.revision_manual.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogDelivery", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeResourcePolicies"]
        Resource = "*"
      }
    ]
  })
}

# ── ECS Task Definitions ──────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "ocr" {
  name              = "/ecs/ocr-processor-${var.environment}"
  retention_in_days = 30
}

resource "aws_ecs_task_definition" "ocr" {
  family                   = "ocr-processor-${var.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "2048"  # 2 vCPU para OCR
  memory                   = "4096"  # 4GB RAM para Tesseract

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name  = "ocr-processor"
    image = "${var.ecr_repository_url}:latest"

    environment = [
      { name = "DOCS_BUCKET", value = var.docs_bucket_name },
      { name = "DYNAMODB_TABLE", value = var.dynamodb_table_name },
      { name = "STEP", value = "ocr" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ocr.name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "ocr"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "extractor" {
  family                   = "data-extractor-${var.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "2048"

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name  = "data-extractor"
    image = "${var.ecr_repository_url}:latest"

    environment = [
      { name = "DOCS_BUCKET", value = var.docs_bucket_name },
      { name = "DYNAMODB_TABLE", value = var.dynamodb_table_name },
      { name = "STEP", value = "extract" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ocr.name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "extractor"
      }
    }
  }])
}

data "aws_region" "current" {}

# ── Lambda: validador y registrador ──────────────────────────────────────────

resource "aws_iam_role" "lambda" {
  name = "docs-lambda-${var.environment}"
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
        Action   = ["s3:GetObject", "s3:HeadObject"]
        Resource = "${var.docs_bucket_arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = var.dynamodb_table_arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

data "archive_file" "validator_code" {
  type        = "zip"
  output_path = "/tmp/docs-validator.zip"
  source {
    content  = <<-PYTHON
      import json, boto3, os

      s3 = boto3.client('s3')

      ALLOWED_TYPES = ['application/pdf', 'image/png', 'image/jpeg', 'image/tiff']
      MAX_SIZE_MB   = 200

      def handler(event, context):
          s3_key  = event['s3_key']
          bucket  = event['bucket']
          doc_id  = event['doc_id']

          head = s3.head_object(Bucket=bucket, Key=s3_key)
          content_type = head.get('ContentType', '')
          size_mb = head['ContentLength'] / (1024 * 1024)

          if content_type not in ALLOWED_TYPES:
              raise ValueError(f"Tipo no soportado: {content_type}")
          if size_mb > MAX_SIZE_MB:
              raise ValueError(f"Tamaño excede {MAX_SIZE_MB}MB: {size_mb:.1f}MB")

          return {**event, 'content_type': content_type, 'size_mb': round(size_mb, 2)}
    PYTHON
    filename = "handler.py"
  }
}

resource "aws_lambda_function" "validator" {
  function_name    = "docs-validator-${var.environment}"
  role             = aws_iam_role.lambda.arn
  filename         = data.archive_file.validator_code.output_path
  source_code_hash = data.archive_file.validator_code.output_base64sha256
  runtime          = "python3.12"
  handler          = "handler.handler"
  timeout          = 10
  environment {
    variables = { DOCS_BUCKET = var.docs_bucket_name }
  }
}

data "archive_file" "registrar_code" {
  type        = "zip"
  output_path = "/tmp/docs-registrar.zip"
  source {
    content  = <<-PYTHON
      import json, boto3, os
      from datetime import datetime, timezone

      ddb = boto3.client('dynamodb')

      def handler(event, context):
          ddb.update_item(
              TableName=os.environ['DYNAMODB_TABLE'],
              Key={'doc_id': {'S': event['doc_id']}},
              UpdateExpression='SET #s = :s, ts_completado = :ts',
              ExpressionAttributeNames={'#s': 'status'},
              ExpressionAttributeValues={
                  ':s':  {'S': 'completado'},
                  ':ts': {'S': datetime.now(timezone.utc).isoformat()}
              }
          )
          return {**event, 'status': 'completado'}
    PYTHON
    filename = "handler.py"
  }
}

resource "aws_lambda_function" "registrar" {
  function_name    = "docs-registrar-${var.environment}"
  role             = aws_iam_role.lambda.arn
  filename         = data.archive_file.registrar_code.output_path
  source_code_hash = data.archive_file.registrar_code.output_base64sha256
  runtime          = "python3.12"
  handler          = "handler.handler"
  timeout          = 10
  environment {
    variables = { DYNAMODB_TABLE = var.dynamodb_table_name }
  }
}

# ── SQS: cola de revisión manual ─────────────────────────────────────────────

resource "aws_sqs_queue" "revision_manual" {
  name                       = "docs-revision-manual-${var.environment}"
  visibility_timeout_seconds = 3600 # 1 hora para que el operador revise
  message_retention_seconds  = 604800 # 7 días
}

# ── CloudWatch Logs para Step Functions ──────────────────────────────────────

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/docs-pipeline-${var.environment}"
  retention_in_days = 90
}

# ── Step Functions: pipeline de documentos ────────────────────────────────────

locals {
  network_config = {
    AwsvpcConfiguration = {
      Subnets        = var.private_subnet_ids
      SecurityGroups = [var.fargate_sg_id]
      AssignPublicIp = "DISABLED"
    }
  }
}

resource "aws_sfn_state_machine" "pipeline" {
  name     = "docs-pipeline-${var.environment}"
  role_arn = aws_iam_role.sfn.arn
  type     = "STANDARD"

  definition = jsonencode({
    Comment = "Pipeline de procesamiento de documentos: OCR → extracción → validación"
    StartAt = "ValidarDocumento"
    States = {

      ValidarDocumento = {
        Type     = "Task"
        Resource = aws_lambda_function.validator.arn
        Retry = [{
          ErrorEquals   = ["Lambda.ServiceException", "Lambda.SdkClientException"]
          MaxAttempts   = 2
          IntervalSeconds = 5
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "DocumentoInvalido"
          ResultPath  = "$.error"
        }]
        Next = "ProcesarOCR"
      }

      ProcesarOCR = {
        Type     = "Task"
        Resource = "arn:aws:states:::ecs:runTask.waitForTaskToken"
        Parameters = {
          LaunchType     = "FARGATE"
          TaskDefinition = aws_ecs_task_definition.ocr.arn
          Cluster        = var.ecs_cluster_arn
          NetworkConfiguration = local.network_config
          Overrides = {
            ContainerOverrides = [{
              Name = "ocr-processor"
              Environment = [
                { Name = "DOC_ID",     "Value.$" = "$.doc_id" }
                { Name = "S3_KEY",     "Value.$" = "$.s3_key" }
                { Name = "TASK_TOKEN", "Value.$" = "$$.Task.Token" }
              ]
            }]
          }
        }
        HeartbeatSeconds = 300  # 5 min heartbeat
        TimeoutSeconds   = 3600 # 1h timeout para PDFs grandes
        ResultPath       = "$.ocr_resultado"
        Retry = [{
          ErrorEquals   = ["States.HeartbeatTimeout"]
          MaxAttempts   = 1
          IntervalSeconds = 60
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "ErrorProcesamiento"
          ResultPath  = "$.error"
        }]
        Next = "ExtraerDatos"
      }

      ExtraerDatos = {
        Type     = "Task"
        Resource = "arn:aws:states:::ecs:runTask.waitForTaskToken"
        Parameters = {
          LaunchType     = "FARGATE"
          TaskDefinition = aws_ecs_task_definition.extractor.arn
          Cluster        = var.ecs_cluster_arn
          NetworkConfiguration = local.network_config
          Overrides = {
            ContainerOverrides = [{
              Name = "data-extractor"
              Environment = [
                { Name = "DOC_ID",     "Value.$" = "$.doc_id" }
                { Name = "S3_KEY",     "Value.$" = "$.ocr_resultado.output_key" }
                { Name = "TASK_TOKEN", "Value.$" = "$$.Task.Token" }
              ]
            }]
          }
        }
        HeartbeatSeconds = 120
        TimeoutSeconds   = 900  # 15 min para extracción NLP
        ResultPath       = "$.extraccion"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "ErrorProcesamiento"
          ResultPath  = "$.error"
        }]
        Next = "ValidarExtraccion"
      }

      ValidarExtraccion = {
        Type = "Choice"
        Choices = [
          {
            Variable      = "$.extraccion.confidence"
            NumericGreaterThanEquals = 0.85
            Next          = "RegistrarCompletado"
          }
        ]
        Default = "EnviarARevisionManual"
      }

      RegistrarCompletado = {
        Type     = "Task"
        Resource = aws_lambda_function.registrar.arn
        End      = true
      }

      EnviarARevisionManual = {
        Type     = "Task"
        Resource = "arn:aws:states:::sqs:sendMessage.waitForTaskToken"
        Parameters = {
          QueueUrl = aws_sqs_queue.revision_manual.id
          MessageBody = {
            taskToken   = { ".$" = "$$.Task.Token" }
            doc_id      = { ".$" = "$.doc_id" }
            extraccion  = { ".$" = "$.extraccion" }
            mensaje     = "Confianza baja — requiere revisión manual"
          }
        }
        HeartbeatSeconds = 86400 # 24h para que el operador revise
        TimeoutSeconds   = 604800 # 7 días máximo en espera
        ResultPath       = "$.revision"
        Next             = "RegistrarCompletado"
        Catch = [{
          ErrorEquals = ["States.TaskTimedOut"]
          Next        = "ErrorProcesamiento"
          ResultPath  = "$.error"
        }]
      }

      DocumentoInvalido = {
        Type  = "Fail"
        Error = "DocumentoInvalido"
        Cause = "El documento no cumple los requisitos de formato o tamaño"
      }

      ErrorProcesamiento = {
        Type  = "Fail"
        Error = "ErrorProcesamiento"
        Cause = "Fallo en el pipeline de procesamiento"
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }
}

output "sfn_arn"                { value = aws_sfn_state_machine.pipeline.arn }
output "revision_queue_url"     { value = aws_sqs_queue.revision_manual.id }
output "ocr_task_definition_arn"{ value = aws_ecs_task_definition.ocr.arn }
