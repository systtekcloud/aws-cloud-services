include "root" {
  path = find_in_parent_folders()
}

locals {
  env = "dev"
}

# Dev: simula 100 sensores, 1 shard Kinesis, on-demand DynamoDB
inputs = {
  environment  = local.env
  shard_count  = 1              # 1 shard = suficiente para 100 sensores dev
  enable_pitr  = false
  s3_lifecycle = "standard"
}
