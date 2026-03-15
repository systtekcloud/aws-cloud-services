# =============================================================================
# Lab02 — Gateway Endpoint vs Interface Endpoint S3
# Terragrunt Configuration
#
# Backend: S3 con locking nativo (Terraform >= 1.10, sin DynamoDB)
# Mismo bucket de estado que lab01 — key diferente por lab
# =============================================================================

locals {
  aws_region = "eu-west-1"
  account_id = get_aws_account_id()
}

# ---------------------------------------------------------------------------
# Remote state — S3 native locking
# Usa el mismo bucket que lab01 (ya debe existir)
# Si no existe: aws s3 mb s3://networking-labs-tfstate-ACCOUNT-eu-west-1
# ---------------------------------------------------------------------------
remote_state {
  backend = "s3"

  config = {
    bucket       = "networking-labs-tfstate-${local.account_id}-${local.aws_region}"
    key          = "lab02-gateway-vs-interface-endpoint-s3/terraform.tfstate"
    region       = local.aws_region
    encrypt      = true
    use_lockfile = true # S3 native locking — requiere Terraform >= 1.10
  }

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------
generate "provider" {
  path      = "provider_override.tf"
  if_exists = "overwrite_terragrunt"

  contents = <<EOF
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
  region = "${local.aws_region}"

  default_tags {
    tags = {
      Project   = "networking-labs"
      Lab       = "lab02-gateway-endpoint-s3"
      Concept   = "GatewayEndpoint-vs-NATGateway-S3"
      ManagedBy = "terragrunt"
    }
  }
}
EOF
}

# ---------------------------------------------------------------------------
# Módulo Terraform
# ---------------------------------------------------------------------------
terraform {
  source = "../terraform"
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
inputs = {
  aws_region = local.aws_region
  prefix     = "lab02"

  vpc_cidr           = "10.0.0.0/16"
  public_subnet_cidr = "10.0.0.0/24"
  subnet_gw_cidr     = "10.0.1.0/24" # CON Gateway Endpoint
  subnet_nat_cidr    = "10.0.2.0/24" # SIN Gateway Endpoint

  az            = "eu-west-1a"
  instance_type = "t3.micro"

  flow_log_retention_days = 1
}
