################################################################################
# Root terragrunt.hcl — configuración compartida por todos los entornos
# Ubicación: terragrunt/terragrunt.hcl
################################################################################

locals {
  # Leer variables del entorno desde env.hcl
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env      = local.env_vars.locals.environment
  region   = local.env_vars.locals.aws_region
  project  = local.env_vars.locals.project
}

# ── Remote State ─────────────────────────────────────────────────────────────
# Bucket y tabla DynamoDB se crean una vez por cuenta/entorno
# aws s3 mb s3://<bucket>
# aws dynamodb create-table --table-name terraform-locks ...

remote_state {
  backend = "s3"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket         = "tfstate-${local.project}-${local.env}-${get_aws_account_id()}"
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = local.region
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}

# ── Provider AWS ──────────────────────────────────────────────────────────────
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"

  contents = <<-EOF
    provider "aws" {
      region = "${local.region}"

      default_tags {
        tags = {
          Project     = "${local.project}"
          Environment = "${local.env}"
          ManagedBy   = "Terragrunt"
        }
      }
    }
  EOF
}

# ── Inputs comunes ────────────────────────────────────────────────────────────
inputs = {
  aws_region  = local.region
  project     = local.project
  environment = local.env
}
