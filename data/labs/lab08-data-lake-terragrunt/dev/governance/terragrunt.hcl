# dev/governance/terragrunt.hcl
#
# Módulo governance: Glue Data Catalog + Lake Formation + IAM roles.
# Depende de storage (necesita el bucket ARN para registrarlo en LF).
#
# Terragrunt resuelve la dependencia automáticamente:
#   terragrunt run-all apply → aplica storage primero, luego governance.

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env      = local.env_vars.locals
}

include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../modules/governance"
}

# ─── Dependencia: storage ─────────────────────────────────────────────────────
# Terragrunt lee los outputs del módulo storage para pasarlos como inputs aquí.
# Si storage no está desplegado, terragrunt apply falla con un error claro.

dependency "storage" {
  config_path = "../storage"

  # mock_outputs permite hacer plan sin que storage esté desplegado.
  # Los mocks no se usan durante apply — solo plan.
  mock_outputs = {
    data_lake_bucket_id  = "mock-bucket"
    data_lake_bucket_arn = "arn:aws:s3:::mock-bucket"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

inputs = {
  name_prefix          = local.env.name_prefix
  region               = local.env.region
  account_id           = local.env.account_id
  common_tags          = local.env.common_tags
  data_lake_bucket_id  = dependency.storage.outputs.data_lake_bucket_id
  data_lake_bucket_arn = dependency.storage.outputs.data_lake_bucket_arn
}
