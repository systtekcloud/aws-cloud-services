include "root" {
  path = find_in_parent_folders()
}

locals {
  env = "prod"
}

# Prod: 10K sensores, shards para ~100KB/s, PITR habilitado
inputs = {
  environment  = local.env
  shard_count  = 2              # 2 shards = 2MB/s headroom para picos
  enable_pitr  = true
  s3_lifecycle = "intelligent_tiering"
}

# Diferencias prod vs dev
# ┌──────────────────────┬──────────────────┬─────────────────────────────┐
# │ Feature              │ Dev              │ Prod                        │
# ├──────────────────────┼──────────────────┼─────────────────────────────┤
# │ Kinesis shards       │ 1                │ 2 (escala automática ON_DEMANDopción) │
# │ Retención Kinesis    │ 24h              │ 7 días                      │
# │ DynamoDB PITR        │ Deshabilitado    │ Habilitado                  │
# │ S3 lifecycle         │ Standard         │ Intelligent-Tiering         │
# │ Alertas CloudWatch   │ Solo errores     │ Errores + P99 latencia      │
# │ Athena workgroup     │ Sin límite $     │ Límite $10/consulta         │
# │ Glue Crawler         │ Manual           │ Diario (02:00 UTC)          │
# └──────────────────────┴──────────────────┴─────────────────────────────┘
