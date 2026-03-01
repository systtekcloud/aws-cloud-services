# =============================================================================
# Modulo ALB (Application Load Balancer) — Entorno DEV
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

# El ALB depende de la VPC para obtener los subnets publicos y el VPC ID
dependency "vpc" {
  config_path = "../vpc"

  # mock_outputs: valores ficticios usados cuando vpc no ha sido aplicado aun.
  # Permite ejecutar `plan` en el ALB sin que la VPC exista todavia.
  # Solo se usan en los comandos especificados en mock_outputs_allowed_terraform_commands.
  mock_outputs = {
    vpc_id            = "vpc-00000000000000000"
    public_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000002"]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  environment = include.env.locals.environment

  # Subnets publicos donde se coloca el ALB (internet-facing)
  vpc_id            = dependency.vpc.outputs.vpc_id
  public_subnet_ids = dependency.vpc.outputs.public_subnet_ids

  # En dev: sin proteccion de eliminacion (permite terraform destroy)
  # En prod: deletion_protection = true para evitar eliminaciones accidentales
  deletion_protection = include.env.locals.alb_deletion_protection

  # El ALB del ShopAPI escucha en el puerto 80 y redirige al puerto 8080 del contenedor
  listener_port     = 80
  target_port       = 8080
  health_check_path = "/health"

  # En dev: intervalos de health check mas frecuentes para detectar problemas rapido
  health_check_interval          = 30
  health_check_healthy_threshold = 2
}
