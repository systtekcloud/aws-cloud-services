# networking/labs/lab05-session-manager/terragrunt/terragrunt.hcl
#
# Root config: S3 backend con native locking (Terraform >= 1.10).
# El mismo bucket S3 de los labs anteriores sirve — el key es único por entorno.

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
      Lab       = "lab05-session-manager"
      ManagedBy = "Terragrunt"
    }
  }
}
EOF
}
