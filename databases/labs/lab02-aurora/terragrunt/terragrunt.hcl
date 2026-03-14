# =============================================================================
# Lab02 Aurora — Terragrunt Configuration
# =============================================================================
# Remote state: S3 + DynamoDB lock
# Requiere que lab01 haya creado la VPC y subnets (o que existan independientemente)
# =============================================================================

locals {
  aws_region = "eu-west-1"
  account_id = get_aws_account_id()
}

# ---------------------------------------------------------------------------
# Remote state backend
# ---------------------------------------------------------------------------

remote_state {
  backend = "s3"

  config = {
    bucket         = "db-labs-tfstate-${local.account_id}-${local.aws_region}"
    key            = "lab02-aurora/terraform.tfstate"
    region         = local.aws_region
    encrypt        = true
    dynamodb_table = "db-labs-tfstate-lock"
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
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "aws" {
  region = "${local.aws_region}"

  default_tags {
    tags = {
      Project   = "db-labs"
      Lab       = "lab02"
      Env       = "lab"
      ManagedBy = "terragrunt"
    }
  }
}
EOF
}

# ---------------------------------------------------------------------------
# Fuente de módulo
# ---------------------------------------------------------------------------

terraform {
  source = "../terraform"
}

# ---------------------------------------------------------------------------
# Inputs (sobreescriben variables.tf defaults)
# ---------------------------------------------------------------------------

inputs = {
  aws_region = local.aws_region

  # Cluster
  aurora_cluster_id     = "db-lab-aurora-cluster"
  aurora_writer_id      = "db-lab-aurora-writer"
  aurora_reader_id      = "db-lab-aurora-reader"
  aurora_engine         = "aurora-mysql"
  aurora_engine_version = "8.0.mysql_aurora.3.04.0"
  aurora_instance_class = "db.t3.medium"
  aurora_db_name        = "auroradb"
  aurora_master_user    = "admin"
  aurora_subnet_group   = "aurora-lab-subnetgroup"

  # Opciones de coste
  enable_reader             = true   # cambiar a false si quieres solo Writer
  reader_promotion_tier     = 0
  enable_deletion_protection = false  # lab: sin protección para facilitar cleanup

  # Backtrack: 1h en lab
  backtrack_window = 3600

  # Backup
  backup_retention_days = 1

  # Secret
  secret_id = "lab02/aurora/admin"

  # KMS: dejar vacío para usar aws/rds
  kms_key_arn = ""

  # Red (debe coincidir con lab01)
  vpc_cidr              = "10.20.0.0/16"
  subnet_private_a_cidr = "10.20.10.0/24"
  subnet_private_b_cidr = "10.20.11.0/24"
  az_a                  = "eu-west-1a"
  az_b                  = "eu-west-1b"
}
