# integration/labs/lab03-sns/terraform/main.tf

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = "eu-west-1" }

locals {
  name_prefix = "lab03-sns"
  tags = { Lab = "lab03-sns", Module = "integration", Managed = "terraform" }
}

# ─── SNS TOPIC ────────────────────────────────────────────────────────────────

resource "aws_sns_topic" "pedidos" {
  name = "${local.name_prefix}-pedidos"
  tags = local.tags
}

# ─── SQS QUEUES (subscribers) ─────────────────────────────────────────────────

resource "aws_sqs_queue" "inventario" {
  name                      = "${local.name_prefix}-inventario"
  message_retention_seconds = 86400
  tags                      = local.tags
}

resource "aws_sqs_queue" "facturacion" {
  name                      = "${local.name_prefix}-facturacion"
  message_retention_seconds = 86400
  tags                      = local.tags
}

resource "aws_sqs_queue" "email" {
  name                      = "${local.name_prefix}-email"
  message_retention_seconds = 86400
  tags                      = local.tags
}

# ─── SQS POLICIES (permitir a SNS escribir) ───────────────────────────────────

data "aws_iam_policy_document" "sqs_sns_policy" {
  for_each = {
    inventario  = aws_sqs_queue.inventario.arn
    facturacion = aws_sqs_queue.facturacion.arn
    email       = aws_sqs_queue.email.arn
  }

  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [each.value]
    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.pedidos.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "inventario" {
  queue_url = aws_sqs_queue.inventario.url
  policy    = data.aws_iam_policy_document.sqs_sns_policy["inventario"].json
}

resource "aws_sqs_queue_policy" "facturacion" {
  queue_url = aws_sqs_queue.facturacion.url
  policy    = data.aws_iam_policy_document.sqs_sns_policy["facturacion"].json
}

resource "aws_sqs_queue_policy" "email" {
  queue_url = aws_sqs_queue.email.url
  policy    = data.aws_iam_policy_document.sqs_sns_policy["email"].json
}

# ─── SNS SUBSCRIPTIONS ────────────────────────────────────────────────────────

# Sin filtering: todos los subscribers reciben todos los mensajes (fan-out puro)
resource "aws_sns_topic_subscription" "inventario" {
  topic_arn = aws_sns_topic.pedidos.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.inventario.arn
}

resource "aws_sns_topic_subscription" "facturacion" {
  topic_arn = aws_sns_topic.pedidos.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.facturacion.arn
}

# Con filtering: email queue solo recibe pedidos con amount >= 100
resource "aws_sns_topic_subscription" "email" {
  topic_arn     = aws_sns_topic.pedidos.arn
  protocol      = "sqs"
  endpoint      = aws_sqs_queue.email.arn
  filter_policy = jsonencode({
    amount = [{ numeric = [">=", 100] }]
  })
}

# ─── OUTPUTS ──────────────────────────────────────────────────────────────────

output "topic_arn"          { value = aws_sns_topic.pedidos.arn }
output "inventario_queue"   { value = aws_sqs_queue.inventario.url }
output "facturacion_queue"  { value = aws_sqs_queue.facturacion.url }
output "email_queue"        { value = aws_sqs_queue.email.url }
