# =============================================================================
# Módulo VPC — Entorno PROD
# =============================================================================

terraform {
  source = "../../../_modules//vpc"
}

include "root" {
  path = find_in_parent_folders()
}

include "env" {
  path   = find_in_parent_folders("env.hcl")
  expose = true
}

inputs = {
  environment        = include.env.locals.environment
  vpc_cidr           = include.env.locals.vpc_cidr
  availability_zones = include.env.locals.availability_zones

  # Prod: 3 AZs → un NAT Gateway por AZ para eliminar el NAT como SPOF.
  # Si una AZ falla, las tasks en las otras AZs siguen usando su propio NAT.
  # Coste adicional: ~$33/mes por NAT Gateway extra vs single_nat_gateway=true.
  single_nat_gateway = false # Recomendado en prod: un NAT por AZ

  # VPC Flow Logs en prod para auditoría de red y detección de anomalías
  enable_flow_logs       = true
  flow_log_retention_days = 30
}
