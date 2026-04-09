# dev/ingestion/terragrunt.hcl
#
# Módulo ingestion: Kinesis Data Stream + Firehose → S3 raw/
# Depende de storage (bucket destino).
#
# Flujo de datos tras el despliegue:
#   aws kinesis put-record --stream-name <kinesis_stream_name> --data '{"event":"test"}' --partition-key "1"
#   → Firehose lo recoge en ~60s y escribe en s3://bucket/raw/year=.../

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env      = local.env_vars.locals
}

include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../modules/ingestion"
}

dependency "storage" {
  config_path = "../storage"

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

  # Dev: buffer más corto para ver datos antes en S3
  kds_shard_count         = 1   # 1MB/s entrada suficiente para dev
  firehose_buffer_seconds = 60  # mínimo de Firehose
  firehose_buffer_mb      = 1   # 1MB en dev (5MB por defecto)
}
