terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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

# ──────────────────────────────────────────────────────────────────────────────
# Detective Graph
# ──────────────────────────────────────────────────────────────────────────────

# NOTE: GuardDuty must be enabled before creating the Detective graph.
# Detective automatically ingests: CloudTrail + VPC Flow Logs + GuardDuty findings
# Behavior graph takes 24-48h to mature after creation.

resource "aws_detective_graph" "main" {
  tags = {
    Lab = "lab08-detective"
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────────────────────────────────────

output "detective_graph_arn" {
  description = "ARN of the Detective behavior graph"
  value       = aws_detective_graph.main.graph_arn
}

output "next_steps" {
  description = "What to do after applying"
  value       = <<-EOT
    Detective behavior graph created: ${aws_detective_graph.main.graph_arn}

    IMPORTANT: Wait 24-48h before the investigation lab.
    The behavior graph needs time to build the baseline of normal activity.

    While waiting:
    1. Generate GuardDuty sample findings:
       aws guardduty create-sample-findings \
         --detector-id $(aws guardduty list-detectors --query 'DetectorIds[0]' --output text) \
         --finding-types "UnauthorizedAccess:EC2/SSHBruteForce" \
                         "Recon:IAMUser/UserPermissions" \
                         "PrivilegeEscalation:IAMUser/AdministrativePermissions" \
         --region ${var.aws_region}

    2. Visit Detective console after 24-48h:
       https://${var.aws_region}.console.aws.amazon.com/detective

    Free trial: 30 days from today.
  EOT
}
