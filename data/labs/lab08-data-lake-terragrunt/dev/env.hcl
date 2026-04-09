# dev/env.hcl — variables del entorno de desarrollo
#
# Este archivo es leído por el root terragrunt.hcl y por cada módulo
# para obtener configuración específica del entorno.
#
# En un setup multi-cuenta real:
#   dev/env.hcl     → account_id de la cuenta dev
#   staging/env.hcl → account_id de la cuenta staging
#   prod/env.hcl    → account_id de la cuenta prod

locals {
  # Obtener el account_id dinámicamente para no hardcodearlo
  account_id  = run_cmd("--terragrunt-quiet", "aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text")
  region      = "eu-west-1"
  environment = "dev"
  project     = "lab08-data-lake"

  # Prefijo para todos los recursos
  name_prefix = "${local.project}-${local.environment}"

  # Tags comunes del entorno
  common_tags = {
    Project     = local.project
    Environment = local.environment
    Region      = local.region
    ManagedBy   = "terragrunt"
  }
}
