include "root" {
  path = find_in_parent_folders()
}

locals {
  env = "prod"
}

terraform {
  source = "../modules/storage"
}

inputs = {
  environment    = local.env
  enable_pitr    = true              # Point-in-time recovery obligatorio en prod (auditoría legal)
  billing_mode   = "PROVISIONED"     # Provisioned + auto-scaling para latencia predecible
  read_capacity  = 25                # Baseline: 25 RCU (~$6/mes), escala hasta 100
  write_capacity = 10                # Baseline: 10 WCU (~$5/mes), escala hasta 100
}

# Diferencias prod vs dev
# ┌────────────────────────┬────────────────────┬──────────────────────────┐
# │ Feature                │ Dev                │ Prod                     │
# ├────────────────────────┼────────────────────┼──────────────────────────┤
# │ DynamoDB billing       │ On-demand          │ Provisioned + autoscaling│
# │ PITR                   │ Deshabilitado      │ Habilitado (2 años TTL)  │
# │ Lambda concurrency     │ Sin límite         │ Reserved: 100            │
# │ SFN logging            │ ERROR              │ ALL (para auditoría)     │
# │ Alarmas CloudWatch     │ Solo DLQ           │ DLQ + SFN failed + P99   │
# │ KMS                    │ AWS managed        │ Customer managed (CMK)   │
# └────────────────────────┴────────────────────┴──────────────────────────┘
