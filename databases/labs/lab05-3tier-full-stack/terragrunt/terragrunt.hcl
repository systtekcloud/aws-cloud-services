# =============================================================================
# Lab05 3-Tier Full Stack — Terragrunt Configuration
# =============================================================================

locals {
  aws_region = "eu-west-1"
  account_id = get_aws_account_id()
}

remote_state {
  backend = "s3"
  config = {
    bucket         = "db-labs-tfstate-${local.account_id}-${local.aws_region}"
    key            = "lab05-3tier-full-stack/terraform.tfstate"
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
    aws    = { source = "hashicorp/aws",    version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
    archive= { source = "hashicorp/archive",version = "~> 2.0" }
  }
}
provider "aws" {
  region = "${local.aws_region}"
  default_tags {
    tags = {
      Project   = "db-labs"
      Lab       = "lab05"
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
  aws_region = local.aws_region
  project    = "db-labs"
  lab        = "lab05"
  env        = "lab"

  # VPC
  vpc_cidr              = "10.20.0.0/16"
  az_a                  = "eu-west-1a"
  az_b                  = "eu-west-1b"
  subnet_public_a_cidr  = "10.20.0.0/24"
  subnet_public_b_cidr  = "10.20.1.0/24"
  subnet_app_a_cidr     = "10.20.10.0/24"
  subnet_app_b_cidr     = "10.20.11.0/24"
  subnet_db_a_cidr      = "10.20.20.0/24"
  subnet_db_b_cidr      = "10.20.21.0/24"

  # Aurora
  aurora_cluster_id     = "aurora-lab05"
  aurora_db_name        = "ecommerce"
  aurora_instance_class = "db.t3.medium"
  aurora_engine_version = "8.0.mysql_aurora.3.04.0"
  aurora_secret_id      = "lab05/aurora/admin"

  # RDS Proxy
  aurora_proxy_id       = "aurora-lab05-proxy"

  # DynamoDB
  dynamo_table_name     = "ecommerce-catalog"

  # Redis
  redis_cluster_id      = "redis-lab05"
  redis_node_type       = "cache.t3.micro"
  redis_engine_version  = "7.1"

  # Lambda + SNS
  lambda_function_name  = "ecommerce-catalog-stream"
  sns_topic_name        = "ecommerce-pedidos-notif"
}
