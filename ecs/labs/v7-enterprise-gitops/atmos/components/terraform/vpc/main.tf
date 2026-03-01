# ── Componente Atmos: VPC ─────────────────────────────────────────────────────
# Este componente es un wrapper que referencia el módulo _modules/vpc.
#
# En un proyecto real, el módulo estaría en un repositorio Git separado:
#   source = "git::https://github.com/tu-org/infra-modules.git//vpc?ref=v1.0.0"
#
# Para este lab, se reutiliza el mismo código desde _modules/ para evitar
# duplicación y mantener un único punto de verdad.

module "vpc" {
  source = "../../../../terragrunt/_modules/vpc"

  environment             = var.environment
  vpc_cidr                = var.vpc_cidr
  availability_zones      = var.availability_zones
  single_nat_gateway      = var.single_nat_gateway
  enable_flow_logs        = var.enable_flow_logs
  flow_log_retention_days = var.flow_log_retention_days
}
