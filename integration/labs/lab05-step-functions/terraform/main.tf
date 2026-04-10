# integration/labs/lab05-step-functions/terraform/main.tf

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.0" }
  }
}

provider "aws" { region = "eu-west-1" }

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "lab05-sfn"
  account_id  = data.aws_caller_identity.current.account_id
  tags = { Lab = "lab05-step-functions", Module = "integration", Managed = "terraform" }
}

# ─── IAM: Lambda execution role ───────────────────────────────────────────────

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals { type = "Service"; identifiers = ["lambda.amazonaws.com"] }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${local.name_prefix}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ─── IAM: Step Functions execution role ───────────────────────────────────────

data "aws_iam_policy_document" "sfn_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals { type = "Service"; identifiers = ["states.amazonaws.com"] }
  }
}

resource "aws_iam_role" "sfn_exec" {
  name               = "${local.name_prefix}-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "sfn_invoke_lambda" {
  name = "invoke-lambdas"
  role = aws_iam_role.sfn_exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = "arn:aws:lambda:eu-west-1:${local.account_id}:function:${local.name_prefix}-*"
    }]
  })
}

resource "aws_iam_role_policy" "sfn_cloudwatch" {
  name = "cloudwatch-logs"
  role = aws_iam_role.sfn_exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogDelivery", "logs:PutLogEvents", "logs:CreateLogGroup", "logs:DescribeLogGroups"]
      Resource = "*"
    }]
  })
}

# ─── LAMBDA FUNCTIONS ─────────────────────────────────────────────────────────

# Función de validación (paso 1 del workflow)
data "archive_file" "validate_zip" {
  type        = "zip"
  output_path = "/tmp/${local.name_prefix}-validate.zip"
  source {
    content  = <<-EOF
      def handler(event, context):
          pedido = event.get('pedido', {})
          if not pedido.get('cliente_id'):
              raise Exception("ValidacionError: cliente_id requerido")
          if pedido.get('total', 0) <= 0:
              raise Exception("ValidacionError: total debe ser > 0")
          return {**event, 'validado': True}
    EOF
    filename = "handler.py"
  }
}

resource "aws_lambda_function" "validate" {
  function_name    = "${local.name_prefix}-validar"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.validate_zip.output_path
  source_code_hash = data.archive_file.validate_zip.output_base64sha256
  timeout          = 10
  tags             = local.tags
}

# Función de procesamiento (paso 2)
data "archive_file" "process_zip" {
  type        = "zip"
  output_path = "/tmp/${local.name_prefix}-process.zip"
  source {
    content  = <<-EOF
      import random
      def handler(event, context):
          if random.random() < 0.1:
              raise Exception("PagoError: tarjeta rechazada")
          return {**event, 'pago_id': f"PAY-{random.randint(1000,9999)}", 'pago_ok': True}
    EOF
    filename = "handler.py"
  }
}

resource "aws_lambda_function" "process" {
  function_name    = "${local.name_prefix}-procesar"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.process_zip.output_path
  source_code_hash = data.archive_file.process_zip.output_base64sha256
  timeout          = 10
  tags             = local.tags
}

# ─── CLOUDWATCH LOG GROUP ─────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/${local.name_prefix}-workflow"
  retention_in_days = 7
  tags              = local.tags
}

# ─── STEP FUNCTIONS — STANDARD WORKFLOW ───────────────────────────────────────

resource "aws_sfn_state_machine" "standard" {
  name     = "${local.name_prefix}-standard-workflow"
  role_arn = aws_iam_role.sfn_exec.arn
  type     = "STANDARD"
  tags     = local.tags

  definition = jsonencode({
    Comment = "Lab 05 — Standard Workflow: validar + procesar pedido"
    StartAt = "ValidarPedido"
    States = {
      ValidarPedido = {
        Type     = "Task"
        Resource = aws_lambda_function.validate.arn
        Next     = "ProcesarPago"
        Retry = [{
          ErrorEquals    = ["Lambda.TooManyRequestsException", "Lambda.ServiceException"]
          IntervalSeconds = 2
          MaxAttempts    = 3
          BackoffRate    = 2
          JitterStrategy = "FULL"
        }]
        Catch = [{
          ErrorEquals = ["Exception"]
          ResultPath  = "$.error"
          Next        = "PedidoRechazado"
        }]
      }
      ProcesarPago = {
        Type     = "Task"
        Resource = aws_lambda_function.process.arn
        End      = true
        Retry = [{
          ErrorEquals    = ["PagoError"]
          IntervalSeconds = 5
          MaxAttempts    = 2
          BackoffRate    = 1.5
        }]
      }
      PedidoRechazado = {
        Type  = "Fail"
        Error = "PedidoInvalido"
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }
}

# ─── STEP FUNCTIONS — EXPRESS WORKFLOW ────────────────────────────────────────

resource "aws_sfn_state_machine" "express" {
  name     = "${local.name_prefix}-express-workflow"
  role_arn = aws_iam_role.sfn_exec.arn
  type     = "EXPRESS"
  tags     = local.tags

  definition = jsonencode({
    Comment = "Lab 05 — Express Workflow: alta frecuencia, sin historial"
    StartAt = "ProcesarEvento"
    States = {
      ProcesarEvento = {
        Type     = "Task"
        Resource = aws_lambda_function.process.arn
        End      = true
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = false
    level                  = "ALL"  # Express necesita ALL para historial via logs
  }
}

# ─── OUTPUTS ──────────────────────────────────────────────────────────────────

output "standard_state_machine_arn" { value = aws_sfn_state_machine.standard.arn }
output "express_state_machine_arn"  { value = aws_sfn_state_machine.express.arn }
output "sfn_role_arn"               { value = aws_iam_role.sfn_exec.arn }
output "lambda_validate_arn"        { value = aws_lambda_function.validate.arn }
output "lambda_process_arn"         { value = aws_lambda_function.process.arn }
