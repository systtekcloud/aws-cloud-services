# Root terragrunt.hcl — configuración compartida por todos los módulos del lab08
#
# Gestiona:
#   - Remote state en S3 + locking en DynamoDB
#   - Provider AWS con región y tags comunes
#   - generate "versions.tf" para garantizar versiones consistentes

locals {
  # Leer variables del entorno activo (dev, staging, prod)
  # Sube hasta encontrar env.hcl en el path
  env_vars    = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  account_id  = local.env_vars.locals.account_id
  region      = local.env_vars.locals.region
  environment = local.env_vars.locals.environment
  project     = local.env_vars.locals.project
}

# ─── Remote State ──────────────────────────────────────────────────────────
# Un bucket S3 por proyecto + DynamoDB para locking
# El state se organiza por: project/environment/module/terraform.tfstate

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = "${local.project}-tfstate-${local.account_id}"
    key            = "${local.project}/${local.environment}/${path_relative_to_include()}/terraform.tfstate"
    region         = local.region
    encrypt        = true
    dynamodb_table = "${local.project}-tfstate-lock"

    # Crear el bucket automáticamente si no existe
    skip_bucket_versioning         = false
    skip_bucket_ssencryption       = false
    skip_bucket_root_access        = false
    skip_bucket_enforced_tls       = false
    skip_bucket_public_access_blocking = false
    enable_lock_table_ssencryption = true
    accesslogging_bucket_name      = null
  }
}

# ─── Provider ────────────────────────────────────────────────────────────────

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = "${local.region}"

  default_tags {
    tags = {
      Project     = "${local.project}"
      Environment = "${local.environment}"
      ManagedBy   = "terragrunt"
    }
  }
}
EOF
}

# ─── Versions ────────────────────────────────────────────────────────────────

generate "versions" {
  path      = "versions.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}
EOF
}
