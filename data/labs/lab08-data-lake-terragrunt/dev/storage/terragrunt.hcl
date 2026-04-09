# dev/storage/terragrunt.hcl
#
# Módulo storage para el entorno dev.
# Base para todos los demás módulos — debe desplegarse primero.
#
# Desplegar: cd dev/storage && terragrunt apply
# Destruir:  cd dev/storage && terragrunt destroy

locals {
  env_vars    = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env         = local.env_vars.locals
}

include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../modules/storage"
}

inputs = {
  name_prefix = local.env.name_prefix
  region      = local.env.region
  common_tags = local.env.common_tags

  # Lifecycle policies: más agresivas en dev para reducir costes
  lifecycle_transition_days  = 30  # raw/ → Glacier IR a los 30 días en dev (90 en prod)
  lifecycle_expiration_days  = 90  # curated/ expira a los 90 días en dev (365 en prod)
}
