include "root" {
  path = find_in_parent_folders()
}

locals {
  env = "dev"
}

# ── Storage (DynamoDB + SNS + KMS) ───────────────────────────────────────────

terraform {
  source = "../modules/storage"
}

inputs = {
  environment  = local.env
  enable_pitr  = false          # PITR tiene coste adicional, solo en prod
  billing_mode = "PAY_PER_REQUEST"  # On-demand: sin coste cuando idle
}

# ── Para levantar todo el stack en dev: ───────────────────────────────────────
# En un repo real, usarías terragrunt run-all con dependencies entre módulos.
# Aquí el stack completo sería:
#
#   storage/   → crea DynamoDB, SNS, KMS
#   queue/     → crea SQS FIFO + DLQ (necesita SNS arn para alarma)
#   processor/ → crea Lambda + Step Functions (necesita DynamoDB + SNS + SQS)
#
# Modo rápido para dev (todo en un apply):

# Para este lab, el stack completo está en un solo módulo raíz main.tf:
# terraform init && terraform apply -var="environment=dev"
