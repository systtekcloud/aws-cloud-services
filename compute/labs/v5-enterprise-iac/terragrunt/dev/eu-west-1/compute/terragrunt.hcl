################################################################################
# dev/eu-west-1/compute/terragrunt.hcl
################################################################################

include "root" {
  path = find_in_parent_folders()
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env      = local.env_vars.locals
}

terraform {
  source = "../../../_modules/compute"
}

# Dependencia del módulo vpc — obtiene outputs automáticamente
dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id             = "vpc-mock"
    public_subnet_ids  = ["subnet-mock-pub-1", "subnet-mock-pub-2"]
    private_subnet_ids = ["subnet-mock-priv-1", "subnet-mock-priv-2"]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  vpc_id             = dependency.vpc.outputs.vpc_id
  public_subnet_ids  = dependency.vpc.outputs.public_subnet_ids
  private_subnet_ids = dependency.vpc.outputs.private_subnet_ids

  instance_type        = local.env.instance_type
  asg_min_size         = local.env.asg_min_size
  asg_max_size         = local.env.asg_max_size
  asg_desired_capacity = local.env.asg_desired_capacity
}
