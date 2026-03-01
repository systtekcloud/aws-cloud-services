# =============================================================================
# Módulo VPC — Entorno STAGING
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

  # Staging: 2 AZs → 2 subnets públicas + 2 privadas
  # Cada AZ tiene su propio NAT Gateway para resiliencia (coste vs disponibilidad)
  single_nat_gateway = false # false = un NAT por AZ (más caro, más resiliente)
}
