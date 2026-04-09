# dev/processing/terragrunt.hcl
#
# Módulo processing: Glue Crawler + ETL Job + EMR Serverless
# Depende de storage (lee/escribe en el bucket) y governance (usa el Glue Catalog)

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env      = local.env_vars.locals
}

include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../modules/processing"
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
  glue_role_arn        = dependency.governance.outputs.glue_role_arn

  # Dev: workers mínimos para reducir costes
  glue_worker_type = "G.1X"  # 4 vCPU, 16GB RAM
  glue_num_workers = 2       # mínimo recomendado para ETL
  emr_cpu_max      = "8 vCPU"
  emr_memory_max   = "16 GB"
}
