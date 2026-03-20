# networking/labs/lab04-vpc-peering-vs-tgw/terragrunt/terragrunt.hcl
#
# Root config: backend S3 con native locking (Terraform >= 1.10, sin DynamoDB)
# y provider AWS. Todos los entornos hijo hacen include de este fichero.

locals {
  region = "eu-west-1"
}

remote_state {
  backend = "s3"
  config = {
    bucket       = "tfstate-networking-labs-<TU_ACCOUNT_ID>"
    key          = "${path_relative_to_include()}/terraform.tfstate"
    region       = local.region
    encrypt      = true
    use_lockfile = true
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
      Lab       = "lab04-vpc-peering-vs-tgw"
      ManagedBy = "Terragrunt"
    }
  }
}
EOF
}
