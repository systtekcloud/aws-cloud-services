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

variable "enable_remediation" {
  description = "Create EventBridge rule + Lambda + SNS for automatic remediation"
  type        = bool
  default     = false
}

variable "alert_email" {
  description = "Email address for GuardDuty HIGH severity alerts (SNS subscription)"
  type        = string
  default     = ""
}

# ──────────────────────────────────────────────────────────────────────────────
# Data sources
# ──────────────────────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

# ──────────────────────────────────────────────────────────────────────────────
# GuardDuty Detector
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_guardduty_detector" "main" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = {
    Lab = "lab04-guardduty"
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# S3 bucket for IP lists
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "ip_lists" {
  bucket        = "lab04-guardduty-lists-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Lab = "lab04-guardduty"
  }
}

# Trusted IP List file
resource "aws_s3_object" "trusted_ips" {
  bucket  = aws_s3_bucket.ip_lists.bucket
  key     = "trusted-ips.txt"
  content = "10.0.0.0/8\n192.168.1.100\n"
}

# Threat IP List file
resource "aws_s3_object" "threat_ips" {
  bucket  = aws_s3_bucket.ip_lists.bucket
  key     = "threat-ips.txt"
  content = "198.51.100.1\n198.51.100.2\n"
}

# ──────────────────────────────────────────────────────────────────────────────
# GuardDuty IP Sets
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_guardduty_ipset" "trusted" {
  detector_id = aws_guardduty_detector.main.id
  name        = "lab04-trusted-ips"
  format      = "TXT"
  location    = "s3://${aws_s3_bucket.ip_lists.bucket}/trusted-ips.txt"
  activate    = true
}

resource "aws_guardduty_threatintelset" "threats" {
  detector_id = aws_guardduty_detector.main.id
  name        = "lab04-threat-ips"
  format      = "TXT"
  location    = "s3://${aws_s3_bucket.ip_lists.bucket}/threat-ips.txt"
  activate    = true
}

# ──────────────────────────────────────────────────────────────────────────────
# GuardDuty Suppression Rule (Filter)
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_guardduty_filter" "suppress_pentest" {
  detector_id = aws_guardduty_detector.main.id
  name        = "suppress-pentest-kali"
  description = "Archiva automáticamente findings de Kali Linux del equipo de pentest"
  action      = "ARCHIVE"
  rank        = 1

  finding_criteria {
    criterion {
      field  = "type"
      equals = ["PenTest:IAMUser/KaliLinux"]
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Remediation infrastructure (optional)
# ──────────────────────────────────────────────────────────────────────────────

# Quarantine Security Group
resource "aws_security_group" "quarantine" {
  count = var.enable_remediation ? 1 : 0

  name        = "lab04-quarantine-sg"
  description = "Security Group de cuarentena — sin acceso entrante ni saliente"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Lab = "lab04-guardduty"
  }
}

# Remove default egress rule from quarantine SG
resource "aws_vpc_security_group_egress_rule" "quarantine_deny_all" {
  count = var.enable_remediation ? 0 : 0
  # Intentionally empty — Terraform manages this via the SG resource
  # The default egress rule is removed via aws_security_group with no egress block
  security_group_id = var.enable_remediation ? aws_security_group.quarantine[0].id : ""
  ip_protocol       = "-1"
  cidr_ipv4         = "255.255.255.255/32"
}

# SNS Topic for alerts
resource "aws_sns_topic" "guardduty_alerts" {
  count = var.enable_remediation ? 1 : 0
  name  = "lab04-guardduty-alerts"

  tags = {
    Lab = "lab04-guardduty"
  }
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.enable_remediation && var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.guardduty_alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# IAM Role for Lambda
resource "aws_iam_role" "remediation_lambda" {
  count = var.enable_remediation ? 1 : 0
  name  = "lab04-guardduty-remediation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Lab = "lab04-guardduty"
  }
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  count      = var.enable_remediation ? 1 : 0
  role       = aws_iam_role.remediation_lambda[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "remediation" {
  count = var.enable_remediation ? 1 : 0
  name  = "lab04-ec2-isolate-policy"
  role  = aws_iam_role.remediation_lambda[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ec2:ModifyInstanceAttribute", "ec2:DescribeSecurityGroups"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = var.enable_remediation ? aws_sns_topic.guardduty_alerts[0].arn : "*"
      }
    ]
  })
}

# Lambda function
data "archive_file" "remediation_lambda" {
  count       = var.enable_remediation ? 1 : 0
  type        = "zip"
  output_path = "/tmp/guardduty_remediation.zip"

  source {
    content  = <<-EOT
      import json, boto3, os
      ec2 = boto3.client('ec2')
      sns = boto3.client('sns')
      QUARANTINE_SG = os.environ.get('QUARANTINE_SG_ID', '')
      SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', '')

      def lambda_handler(event, context):
          finding = event.get('detail', {})
          finding_type = finding.get('type', 'Unknown')
          severity = finding.get('severity', 0)
          resource_type = finding.get('resource', {}).get('resourceType', 'Unknown')
          message = f"GuardDuty Finding\nTipo: {finding_type}\nSeveridad: {severity}\nRecurso: {resource_type}"
          if resource_type == 'Instance' and QUARANTINE_SG:
              instance_id = finding.get('resource', {}).get('instanceDetails', {}).get('instanceId', '')
              if instance_id:
                  try:
                      ec2.modify_instance_attribute(InstanceId=instance_id, Groups=[QUARANTINE_SG])
                      message += f"\nACCIÓN: EC2 {instance_id} aislada"
                  except Exception as e:
                      message += f"\nERROR: {str(e)}"
          if SNS_TOPIC_ARN:
              sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=f"[ALERTA] GuardDuty HIGH: {finding_type}", Message=message)
          return {'statusCode': 200}
    EOT
    filename = "guardduty_remediation.py"
  }
}

resource "aws_lambda_function" "remediation" {
  count = var.enable_remediation ? 1 : 0

  function_name    = "lab04-guardduty-isolate"
  role             = aws_iam_role.remediation_lambda[0].arn
  handler          = "guardduty_remediation.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.remediation_lambda[0].output_path
  source_code_hash = data.archive_file.remediation_lambda[0].output_base64sha256
  timeout          = 30

  environment {
    variables = {
      QUARANTINE_SG_ID = aws_security_group.quarantine[0].id
      SNS_TOPIC_ARN    = aws_sns_topic.guardduty_alerts[0].arn
    }
  }

  tags = {
    Lab = "lab04-guardduty"
  }
}

# EventBridge Rule
resource "aws_cloudwatch_event_rule" "guardduty_high" {
  count = var.enable_remediation ? 1 : 0

  name        = "lab04-guardduty-high-severity"
  description = "Reacciona a findings GuardDuty HIGH severity (>= 7)"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ "numeric" = [">=", 7] }]
    }
  })

  tags = {
    Lab = "lab04-guardduty"
  }
}

resource "aws_lambda_permission" "eventbridge" {
  count = var.enable_remediation ? 1 : 0

  statement_id  = "EventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.guardduty_high[0].arn
}

resource "aws_cloudwatch_event_target" "lambda" {
  count = var.enable_remediation ? 1 : 0

  rule = aws_cloudwatch_event_rule.guardduty_high[0].name
  arn  = aws_lambda_function.remediation[0].arn
  target_id = "lambda-target"
}

resource "aws_cloudwatch_event_target" "sns" {
  count = var.enable_remediation ? 1 : 0

  rule      = aws_cloudwatch_event_rule.guardduty_high[0].name
  arn       = aws_sns_topic.guardduty_alerts[0].arn
  target_id = "sns-target"
}

resource "aws_sns_topic_policy" "events" {
  count = var.enable_remediation ? 1 : 0
  arn   = aws_sns_topic.guardduty_alerts[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.guardduty_alerts[0].arn
    }]
  })
}

# ──────────────────────────────────────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────────────────────────────────────

output "detector_id" {
  value = aws_guardduty_detector.main.id
}

output "ip_lists_bucket" {
  value = aws_s3_bucket.ip_lists.bucket
}

output "trusted_ipset_id" {
  value = aws_guardduty_ipset.trusted.id
}

output "threat_intel_set_id" {
  value = aws_guardduty_threatintelset.threats.id
}

output "suppression_rule_name" {
  value = aws_guardduty_filter.suppress_pentest.name
}

output "quarantine_sg_id" {
  value = var.enable_remediation ? aws_security_group.quarantine[0].id : "not created"
}

output "sns_topic_arn" {
  value = var.enable_remediation ? aws_sns_topic.guardduty_alerts[0].arn : "not created"
}
