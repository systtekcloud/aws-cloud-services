# =============================================================================
# Lab04 ElastiCache Redis — Terragrunt Configuration
# =============================================================================

locals {
  aws_region = "eu-west-1"
  account_id = get_aws_account_id()
}

remote_state {
  backend = "s3"
  config = {
    bucket         = "db-labs-tfstate-${local.account_id}-${local.aws_region}"
    key            = "lab04-elasticache/terraform.tfstate"
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
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}
provider "aws" {
  region = "${local.aws_region}"
  default_tags {
    tags = {
      Project   = "db-labs"
      Lab       = "lab04"
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
  aws_region   = local.aws_region
  project      = "db-labs"
  lab          = "lab04"
  env          = "lab"

  redis_cluster_id     = "redis-lab-cluster"
  redis_node_type      = "cache.t3.micro"
  redis_engine_version = "7.1"
  redis_num_clusters   = 2  # primary + 1 replica

  enable_multi_az    = true
  at_rest_encryption = true
  transit_encryption = true
  snapshot_retention = 0  # lab: sin snapshots

  redis_subnet_group    = "redis-lab-subnetgroup"
  vpc_cidr              = "10.20.0.0/16"
  subnet_private_a_cidr = "10.20.10.0/24"
  subnet_private_b_cidr = "10.20.11.0/24"
  az_a                  = "eu-west-1a"
  az_b                  = "eu-west-1b"
}
