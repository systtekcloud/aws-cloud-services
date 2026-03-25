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

variable "enable_cis" {
  description = "Enable CIS AWS Foundations Benchmark standard"
  type        = bool
  default     = true
}

variable "enable_pci_dss" {
  description = "Enable PCI-DSS standard"
  type        = bool
  default     = false
}

# ──────────────────────────────────────────────────────────────────────────────
# Security Hub
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_securityhub_account" "main" {
  enable_default_standards = true  # Enables AWS FSBP automatically

  tags = {
    Lab = "lab05-security-hub"
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Standards subscriptions
# ──────────────────────────────────────────────────────────────────────────────

# CIS AWS Foundations Benchmark
resource "aws_securityhub_standards_subscription" "cis" {
  count         = var.enable_cis ? 1 : 0
  standards_arn = "arn:aws:securityhub:${var.aws_region}::standards/cis-aws-foundations-benchmark/v/1.4.0"

  depends_on = [aws_securityhub_account.main]
}

# PCI-DSS (optional)
resource "aws_securityhub_standards_subscription" "pci_dss" {
  count         = var.enable_pci_dss ? 1 : 0
  standards_arn = "arn:aws:securityhub:${var.aws_region}::standards/pci-dss/v/3.2.1"

  depends_on = [aws_securityhub_account.main]
}

# ──────────────────────────────────────────────────────────────────────────────
# Insight: High severity findings by product
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_securityhub_insight" "high_severity_by_product" {
  name = "lab05-high-severity-by-product"

  filters {
    severity_label {
      comparison = "EQUALS"
      value      = "HIGH"
    }
    severity_label {
      comparison = "EQUALS"
      value      = "CRITICAL"
    }
    record_state {
      comparison = "EQUALS"
      value      = "ACTIVE"
    }
    workflow_status {
      comparison = "EQUALS"
      value      = "NEW"
    }
  }

  group_by_attribute = "ProductName"

  depends_on = [aws_securityhub_account.main]
}

# ──────────────────────────────────────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────────────────────────────────────

output "security_hub_arn" {
  value = aws_securityhub_account.main.id
}

output "cis_standard_arn" {
  value = var.enable_cis ? aws_securityhub_standards_subscription.cis[0].id : "not enabled"
}

output "insight_arn" {
  value = aws_securityhub_insight.high_severity_by_product.id
}
