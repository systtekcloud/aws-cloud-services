# =============================================================================
# Modulo VPC — Entorno DEV
# =============================================================================

terraform {
  # source apunta al modulo reutilizable en _modules/vpc
  # La doble barra (//) indica a Terragrunt donde empieza el modulo dentro del repo
  # Para usar un modulo versionado desde Git:
  #   source = "git::https://github.com/org/infra-modules.git//vpc?ref=v1.2.0"
  source = "../../../_modules//vpc"
}

# Heredar la configuracion raiz (backend S3 + provider AWS)
include "root" {
  path = find_in_parent_folders()
}

# Leer las variables del entorno desde env.hcl
include "env" {
  path   = find_in_parent_folders("env.hcl")
  expose = true # expose = true permite acceder a los locals de env.hcl
}

# Pasar las variables del entorno como inputs al modulo Terraform
inputs = {
  # Nombre del entorno para nombrar los recursos (shopapi-vpc-dev)
  environment = include.env.locals.environment

  # Bloque CIDR de la VPC (unico por entorno para evitar solapamientos)
  vpc_cidr = include.env.locals.vpc_cidr

  # En dev: una sola AZ para reducir el coste de NAT Gateways
  # AWS cobra por NAT Gateway por AZ: usar 1 AZ = 1 NAT Gateway = menor coste
  availability_zones = include.env.locals.availability_zones

  # En dev no se necesita NAT Gateway de alta disponibilidad
  # Se puede usar un unico NAT Gateway en la primera AZ
  single_nat_gateway = true

  # Habilitar DNS hostnames para que las instancias ECS puedan resolver nombres
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tags adicionales especificos de VPC
  tags = {
    Component = "networking"
    Layer     = "base"
  }
}
