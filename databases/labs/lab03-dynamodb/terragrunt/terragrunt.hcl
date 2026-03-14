# =============================================================================
# Lab03 DynamoDB — Terragrunt Configuration
# =============================================================================

locals {
  aws_region = "eu-west-1"
  account_id = get_aws_account_id()
}

remote_state {
  backend = "s3"
  config = {
    bucket         = "db-labs-tfstate-${local.account_id}-${local.aws_region}"
    key            = "lab03-dynamodb/terraform.tfstate"
    region         = local.aws_region
    encrypt        = true
    dynamodb_table = "db-labs-tfstate-lock"
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}

generate "provider" {
  path      = "provider_override.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws     = { source = "hashicorp/aws",  version = "~> 5.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}
provider "aws" {
  region = "${local.aws_region}"
  default_tags {
    tags = {
      Project   = "db-labs"
      Lab       = "lab03"
      Env       = "lab"
      ManagedBy = "terragrunt"
    }
  }
}
EOF
}

terraform {
  source = "../terraform"
}

inputs = {
  aws_region            = local.aws_region
  table_name            = "ecommerce-orders"
  billing_mode          = "PAY_PER_REQUEST"
  ttl_attribute         = "ttl"
  enable_streams        = true
  stream_view_type      = "NEW_AND_OLD_IMAGES"
  enable_lambda_trigger = true
  lambda_function_name  = "dynamodb-stream-processor"
  enable_pitr           = false
  alert_email           = ""  # añadir email para recibir alertas de throttling
}
