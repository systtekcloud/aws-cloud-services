################################################################################
# dev/eu-west-1/vpc/terragrunt.hcl
################################################################################

include "root" {
  path = find_in_parent_folders()
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env      = local.env_vars.locals
}

terraform {
  source = "../../../_modules/vpc"
}

inputs = {
  vpc_cidr              = local.env.vpc_cidr
  public_subnets_cidrs  = local.env.public_subnets_cidrs
  private_subnets_cidrs = local.env.private_subnets_cidrs
  single_nat_gateway    = local.env.single_nat_gateway
  enable_nat_gateway    = true
}
