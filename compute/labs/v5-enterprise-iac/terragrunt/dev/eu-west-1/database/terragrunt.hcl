################################################################################
# dev/eu-west-1/database/terragrunt.hcl
################################################################################

include "root" {
  path = find_in_parent_folders()
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env      = local.env_vars.locals
}

terraform {
  source = "../../../_modules/database"
}

dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id             = "vpc-mock"
    private_subnet_ids = ["subnet-mock-1", "subnet-mock-2", "subnet-mock-3"]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "compute" {
  config_path = "../compute"
  mock_outputs = {
    ec2_sg_id = "sg-mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  vpc_id             = dependency.vpc.outputs.vpc_id
  private_subnet_ids = dependency.vpc.outputs.private_subnet_ids
  ec2_sg_id          = dependency.compute.outputs.ec2_sg_id

  db_instance_class = local.env.db_instance_class
  redis_node_type   = local.env.redis_node_type
  db_name           = "shopdb"
}
