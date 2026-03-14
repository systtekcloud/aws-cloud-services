# =============================================================================
# Lab01 — PrivateLink con CIDRs solapados
# Terragrunt Configuration
#
# Concepto: dos VPCs con el mismo CIDR (10.0.0.0/16) comunican via PrivateLink.
# VPC Peering falla con CIDRs solapados — PrivateLink no depende de enrutamiento IP.
#
# Backend: S3 con locking nativo (Terraform >= 1.10, sin DynamoDB)
# =============================================================================

locals {
  aws_region = "eu-west-1"
  account_id = get_aws_account_id()
}

# ---------------------------------------------------------------------------
# Remote state — S3 native locking (sin DynamoDB)
# Requiere crear el bucket antes: aws s3 mb s3://networking-labs-tfstate-ACCOUNT-eu-west-1
# ---------------------------------------------------------------------------
remote_state {
  backend = "s3"

  config = {
    bucket       = "networking-labs-tfstate-${local.account_id}-${local.aws_region}"
    key          = "lab01-privatelink-cidr-overlap/terraform.tfstate"
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
      Lab       = "lab01-privatelink"
      Concept   = "PrivateLink-overlapping-CIDRs"
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
  prefix     = "lab01"

  # Ambas VPCs usan el mismo CIDR — esto hace imposible el VPC Peering
  vpc_cidr = "10.0.0.0/16"

  # Subnets dentro de cada VPC (distintos rangos, pero dentro del mismo /16)
  vpc_a_subnet_cidr = "10.0.1.0/24" # VPC-A: consumer (subnet pública)
  vpc_b_subnet_cidr = "10.0.2.0/24" # VPC-B: provider (subnet privada con NLB)

  az            = "eu-west-1a"
  instance_type = "t3.micro"
}
