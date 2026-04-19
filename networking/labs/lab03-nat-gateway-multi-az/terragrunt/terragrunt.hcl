# networking/labs/lab03-nat-gateway-multi-az/terragrunt/terragrunt.hcl
#
# Root Terragrunt config. Define backend S3 (native locking, sin DynamoDB)
# y el provider AWS. Todos los entornos hijo hacen include de este fichero.

locals {
  region = "eu-west-1"
}

remote_state {
  backend = "s3"
  config = {
    bucket         = "tfstate-networking-labs-<TU_ACCOUNT_ID>"
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = local.region
    encrypt        = true
    use_lockfile   = true   # S3 native locking (Terraform >= 1.10, sin DynamoDB)
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = "${local.region}"
  default_tags {
    tags = {
      Lab       = "lab03-nat-gateway-multi-az"
      ManagedBy = "Terragrunt"
    }
  }
}
EOF
}
