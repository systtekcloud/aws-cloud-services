# =============================================================================
# Módulo ALB — Entorno STAGING
# =============================================================================

terraform {
  source = "../../../_modules//alb"
}

include "root" {
  path = find_in_parent_folders()
}

include "env" {
  path   = find_in_parent_folders("env.hcl")
  expose = true
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id            = "vpc-00000000000000000"
    public_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000002"]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  environment = include.env.locals.environment

  vpc_id            = dependency.vpc.outputs.vpc_id
  public_subnet_ids = dependency.vpc.outputs.public_subnet_ids

  # Staging: sin deletion protection para poder destruir el entorno fácilmente
  deletion_protection = include.env.locals.alb_deletion_protection

  # Health check más estricto en staging (detecta problemas antes de prod)
  health_check_path     = "/health"
  health_check_interval = 30
  health_check_timeout  = 5
  healthy_threshold     = 2
  unhealthy_threshold   = 3

  # Deregistration delay más corto en staging (deploys más rápidos)
  deregistration_delay = 30 # segundos (prod usa 300)
}
