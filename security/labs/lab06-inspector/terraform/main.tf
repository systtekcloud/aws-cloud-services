terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ──────────────────────────────────────────────────────────────────────────────
# Variables
# ──────────────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "enable_ec2_scanning" {
  description = "Enable Inspector EC2 scanning"
  type        = bool
  default     = true
}

variable "enable_ecr_scanning" {
  description = "Enable Inspector ECR scanning"
  type        = bool
  default     = true
}

variable "enable_lambda_scanning" {
  description = "Enable Inspector Lambda scanning"
  type        = bool
  default     = false
}

variable "notification_email" {
  description = "Email for SNS notifications (optional)"
  type        = string
  default     = ""
}

data "aws_caller_identity" "current" {}

# ──────────────────────────────────────────────────────────────────────────────
# Inspector enabler
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_inspector2_enabler" "main" {
  account_ids = [data.aws_caller_identity.current.account_id]

  resource_types = concat(
    var.enable_ec2_scanning ? ["EC2"] : [],
    var.enable_ecr_scanning ? ["ECR"] : [],
    var.enable_lambda_scanning ? ["LAMBDA"] : []
  )
}

# ──────────────────────────────────────────────────────────────────────────────
# ECR Repository
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "demo" {
  name                 = "lab06-inspector-demo"
  image_tag_mutability = "MUTABLE"

  # scanOnPush false because Inspector handles scanning (Enhanced)
  image_scanning_configuration {
    scan_on_push = false
  }

  tags = {
    Lab = "lab06-inspector"
  }
}

# Configure Enhanced Scanning (managed via Inspector, not ECR)
resource "aws_ecr_registry_scanning_configuration" "enhanced" {
  scan_type = "ENHANCED"

  rule {
    scan_frequency = "CONTINUOUS_SCAN"

    repository_filter {
      filter      = "lab06-*"
      filter_type = "WILDCARD"
    }
  }

  depends_on = [aws_inspector2_enabler.main]
}

# ──────────────────────────────────────────────────────────────────────────────
# SNS Topic for notifications
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_sns_topic" "inspector_alerts" {
  name = "lab06-inspector-alerts"

  tags = {
    Lab = "lab06-inspector"
  }
}

resource "aws_sns_topic_policy" "inspector_alerts" {
  arn = aws_sns_topic.inspector_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.inspector_alerts.arn
    }]
  })
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.inspector_alerts.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# ──────────────────────────────────────────────────────────────────────────────
# Lambda for pipeline blocking simulation
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "lambda_inspector" {
  name = "lab06-lambda-inspector-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_inspector.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "/tmp/lab06-lambda.zip"

  source {
    content  = <<PYTHON
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def handler(event, context):
    detail = event.get("detail", {})
    severity = detail.get("severity", "UNKNOWN")
    pkg_vuln = detail.get("packageVulnerabilityDetails", {})
    cve_id = pkg_vuln.get("vulnerabilityId", "UNKNOWN")
    resources = detail.get("resources", [{}])
    resource_id = resources[0].get("id", "UNKNOWN") if resources else "UNKNOWN"

    message = {
        "alert_type": "INSPECTOR_CRITICAL_FINDING",
        "action": "PIPELINE_BLOCKED",
        "severity": severity,
        "cve_id": cve_id,
        "resource_id": resource_id,
        "action_taken": "Pipeline bloqueado (simulado). En producción: GitHub/GitLab API call."
    }

    logger.info("Inspector finding procesado: %s", json.dumps(message))
    return {"statusCode": 200, "body": json.dumps(message)}
PYTHON
    filename = "index.py"
  }
}

resource "aws_lambda_function" "pipeline_blocker" {
  function_name = "lab06-inspector-pipeline-blocker"
  role          = aws_iam_role.lambda_inspector.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 30

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  tags = {
    Lab = "lab06-inspector"
  }
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pipeline_blocker.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.inspector_critical.arn
}

# ──────────────────────────────────────────────────────────────────────────────
# EventBridge Rule
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_event_rule" "inspector_critical" {
  name        = "lab06-inspector-critical-ecr"
  description = "Inspector CRITICAL findings en ECR → bloquear pipeline"

  event_pattern = jsonencode({
    source      = ["aws.inspector2"]
    detail-type = ["Inspector2 Finding"]
    detail = {
      severity = ["CRITICAL"]
      resources = {
        type = ["AWS_ECR_CONTAINER_IMAGE"]
      }
    }
  })

  tags = {
    Lab = "lab06-inspector"
  }
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule      = aws_cloudwatch_event_rule.inspector_critical.name
  target_id = "lambda-pipeline-blocker"
  arn       = aws_lambda_function.pipeline_blocker.arn
}

resource "aws_cloudwatch_event_target" "sns" {
  rule      = aws_cloudwatch_event_rule.inspector_critical.name
  target_id = "sns-team-notification"
  arn       = aws_sns_topic.inspector_alerts.arn
}

# ──────────────────────────────────────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────────────────────────────────────

output "ecr_repository_url" {
  value = aws_ecr_repository.demo.repository_url
}

output "sns_topic_arn" {
  value = aws_sns_topic.inspector_alerts.arn
}

output "lambda_function_arn" {
  value = aws_lambda_function.pipeline_blocker.arn
}

output "eventbridge_rule_arn" {
  value = aws_cloudwatch_event_rule.inspector_critical.arn
}
