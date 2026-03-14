# =============================================================================
# Lab 01 — RDS MySQL: Terragrunt Configuration
#
# Uso:
#   cd databases/labs/lab01-rds-basico/terragrunt
#   terragrunt plan
#   terragrunt apply
#   terragrunt destroy
#
# Prerequisito: bucket S3 y tabla DynamoDB para el state backend
#   El bucket se crea automáticamente si no existe (create_before_destroy = true)
# =============================================================================

locals {
  # Detectar account ID y región automáticamente
  aws_region = "eu-west-1"
  account_id = get_aws_account_id()

  # Valores del lab
  project = "db-labs"
  lab     = "lab01"
  env     = "lab"
}

# =============================================================================
# REMOTE STATE BACKEND (S3 + DynamoDB lock)
# =============================================================================
remote_state {
  backend = "s3"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket         = "db-labs-tfstate-${local.account_id}-${local.aws_region}"
    key            = "${local.lab}/terraform.tfstate"
    region         = local.aws_region
    encrypt        = true
    dynamodb_table = "db-labs-tfstate-lock"

    # Crear el bucket si no existe
    s3_bucket_tags = {
      Project   = local.project
      ManagedBy = "terragrunt"
    }
  }
}

# =============================================================================
# GENERATE PROVIDER
# =============================================================================
generate "provider" {
  path      = "provider_override.tf"
  if_exists = "overwrite_terragrunt"

  contents = <<EOF
provider "aws" {
  region = "${local.aws_region}"

  default_tags {
    tags = {
      Project   = "${local.project}"
      Lab       = "${local.lab}"
      ManagedBy = "terragrunt"
      Env       = "${local.env}"
    }
  }
}
EOF
}

# =============================================================================
# INPUTS → pasan como variables al módulo terraform/
# =============================================================================
inputs = {
  aws_region = local.aws_region
  project    = local.project
  lab        = local.lab
  env        = local.env

  # Red
  vpc_cidr              = "10.20.0.0/16"
  subnet_public_a_cidr  = "10.20.1.0/24"
  subnet_public_b_cidr  = "10.20.2.0/24"
  subnet_db_a_cidr      = "10.20.11.0/24"
  subnet_db_b_cidr      = "10.20.12.0/24"
  subnet_app_a_cidr     = "10.20.21.0/24"

  # RDS
  rds_instance_class      = "db.t3.micro"
  rds_engine_version      = "8.0"
  rds_storage_gb          = 20
  rds_db_name             = "labdb"
  backup_retention_period = 7

  # HA (false = Single-AZ para ahorrar coste en el lab)
  enable_multi_az      = false
  enable_read_replica  = false
}

# =============================================================================
# TERRAFORM SOURCE
# =============================================================================
terraform {
  source = "../terraform"
}
