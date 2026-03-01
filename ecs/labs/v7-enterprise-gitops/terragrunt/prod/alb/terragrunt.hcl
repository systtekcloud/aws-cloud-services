# =============================================================================
# Módulo ALB — Entorno PROD
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
    public_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000002", "subnet-00000000000000003"]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  environment = include.env.locals.environment

  vpc_id            = dependency.vpc.outputs.vpc_id
  public_subnet_ids = dependency.vpc.outputs.public_subnet_ids

  # Prod: activar protección contra eliminación accidental
  deletion_protection = include.env.locals.alb_deletion_protection

  # Health check conservador: más intentos antes de marcar unhealthy
  health_check_path     = "/health"
  health_check_interval = 30
  health_check_timeout  = 5
  healthy_threshold     = 3
  unhealthy_threshold   = 5

  # Deregistration delay: 300s (5 min) para que las requests en vuelo terminen
  # Crítico para APIs con operaciones largas o conexiones WebSocket
  deregistration_delay = 300

  # Access logs en S3 para auditoría y análisis de tráfico
  access_logs_enabled    = true
  access_logs_bucket     = "shopapi-alb-logs-${include.env.locals.account_id}"
  access_logs_prefix     = "prod-alb"

  # HTTPS: en un entorno real, configurar listener HTTPS con certificado ACM
  # enable_https        = true
  # certificate_arn     = "arn:aws:acm:eu-west-1:ACCOUNT:certificate/xxx"
}
