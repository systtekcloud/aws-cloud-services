# dev/serving/terragrunt.hcl
#
# Módulo serving: Redshift Serverless + Redshift Spectrum
# Depende de storage y governance (necesita Glue Catalog para Spectrum)
#
# ⚠️ COSTE: Redshift Serverless cobra por RPU-hora cuando está activo.
#    8 RPU × $0.36/RPU-hora = ~$2.88/hora (solo cuando procesa queries).
#    Pausar el workgroup tras el lab o destruir con terragrunt destroy.

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env      = local.env_vars.locals
}

include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../modules/serving"
}

dependency "storage" {
  config_path = "../storage"

  mock_outputs = {
    data_lake_bucket_id  = "mock-bucket"
    data_lake_bucket_arn = "arn:aws:s3:::mock-bucket"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "governance" {
  config_path = "../governance"

  mock_outputs = {
    glue_database_name = "mock_database"
    glue_role_arn      = "arn:aws:iam::123456789012:role/mock-glue-role"
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
  glue_database_name   = dependency.governance.outputs.glue_database_name

  # Dev: capacidad mínima para reducir costes
  redshift_base_capacity = 8  # mínimo Serverless (8 RPU = 64GB RAM)

  # En producción usar AWS Secrets Manager, no variables hardcodeadas
  redshift_admin_user     = "admin"
  redshift_admin_password = "Lab08Dev2024!"
}
