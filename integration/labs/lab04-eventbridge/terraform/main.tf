# integration/labs/lab04-eventbridge/terraform/main.tf

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = "eu-west-1" }

locals {
  name_prefix = "lab04-eb"
  tags = { Lab = "lab04-eventbridge", Module = "integration", Managed = "terraform" }
}

# ─── CUSTOM EVENT BUS ─────────────────────────────────────────────────────────

resource "aws_cloudwatch_event_bus" "main" {
  name = "${local.name_prefix}-main"
  tags = local.tags
}

# ─── TARGETS: SQS QUEUES ──────────────────────────────────────────────────────

resource "aws_sqs_queue" "high_value" {
  name = "${local.name_prefix}-high-value"
  tags = local.tags
}

resource "aws_sqs_queue" "international" {
  name = "${local.name_prefix}-international"
  tags = local.tags
}

data "aws_iam_policy_document" "sqs_eb_policy" {
  for_each = {
    high_value    = aws_sqs_queue.high_value.arn
    international = aws_sqs_queue.international.arn
  }
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [each.value]
    principals { type = "Service"; identifiers = ["events.amazonaws.com"] }
  }
}

resource "aws_sqs_queue_policy" "high_value" {
  queue_url = aws_sqs_queue.high_value.url
  policy    = data.aws_iam_policy_document.sqs_eb_policy["high_value"].json
}

resource "aws_sqs_queue_policy" "international" {
  queue_url = aws_sqs_queue.international.url
  policy    = data.aws_iam_policy_document.sqs_eb_policy["international"].json
}

# ─── CLOUDWATCH LOGS (target de auditoría) ────────────────────────────────────

resource "aws_cloudwatch_log_group" "events" {
  name              = "/aws/events/${local.name_prefix}"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_cloudwatch_log_resource_policy" "events" {
  policy_name = "${local.name_prefix}-logs-policy"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "${aws_cloudwatch_log_group.events.arn}:*"
    }]
  })
}

# ─── RULES ────────────────────────────────────────────────────────────────────

# Regla 1: catch-all → CloudWatch Logs
resource "aws_cloudwatch_event_rule" "catch_all" {
  name           = "${local.name_prefix}-catch-all"
  event_bus_name = aws_cloudwatch_event_bus.main.name
  event_pattern  = jsonencode({ source = [{ prefix = "" }] })
  tags           = local.tags
}

resource "aws_cloudwatch_event_target" "catch_all_logs" {
  rule           = aws_cloudwatch_event_rule.catch_all.name
  event_bus_name = aws_cloudwatch_event_bus.main.name
  target_id      = "logs"
  arn            = aws_cloudwatch_log_group.events.arn
}

# Regla 2: pedidos de alto valor → SQS
resource "aws_cloudwatch_event_rule" "high_value" {
  name           = "${local.name_prefix}-high-value"
  event_bus_name = aws_cloudwatch_event_bus.main.name
  event_pattern = jsonencode({
    source        = ["com.miempresa.pedidos"]
    "detail-type" = ["PedidoCreado"]
    detail = {
      total = [{ numeric = [">=", 500] }]
    }
  })
  tags = local.tags
}

resource "aws_cloudwatch_event_target" "high_value_sqs" {
  rule           = aws_cloudwatch_event_rule.high_value.name
  event_bus_name = aws_cloudwatch_event_bus.main.name
  target_id      = "high-value-queue"
  arn            = aws_sqs_queue.high_value.arn
}

# Regla 3: pedidos internacionales → SQS con input transformer
resource "aws_cloudwatch_event_rule" "international" {
  name           = "${local.name_prefix}-international"
  event_bus_name = aws_cloudwatch_event_bus.main.name
  event_pattern = jsonencode({
    source        = ["com.miempresa.pedidos"]
    "detail-type" = ["PedidoCreado"]
    detail = {
      tipo = ["international"]
    }
  })
  tags = local.tags
}

resource "aws_cloudwatch_event_target" "international_sqs" {
  rule           = aws_cloudwatch_event_rule.international.name
  event_bus_name = aws_cloudwatch_event_bus.main.name
  target_id      = "international-queue"
  arn            = aws_sqs_queue.international.arn

  input_transformer {
    input_paths = {
      pedido_id = "$.detail.pedido_id"
      total     = "$.detail.total"
      pais      = "$.detail.pais_destino"
    }
    input_template = <<-EOT
      {"pedido": "<pedido_id>", "total": <total>, "aduanas_pais": "<pais>"}
    EOT
  }
}

# ─── OUTPUTS ──────────────────────────────────────────────────────────────────

output "event_bus_name"      { value = aws_cloudwatch_event_bus.main.name }
output "event_bus_arn"       { value = aws_cloudwatch_event_bus.main.arn }
output "high_value_queue"    { value = aws_sqs_queue.high_value.url }
output "international_queue" { value = aws_sqs_queue.international.url }
