# =============================================================================
# Variables del Entorno: STAGING
# =============================================================================
#
# Staging es una réplica fiel de producción en configuración pero con:
#   - Menos tasks (menor coste)
#   - Mayor tolerancia a Fargate Spot (las interrupciones son aceptables)
#   - Logs con retención más corta que prod
#   - Sin Deletion Protection en ALB (permite destruir con terragrunt destroy)
#
# Propósito: validar deploys exactamente como prod antes de promoverlos.
# La infraestructura debe ser structuralmente idéntica a prod.
# =============================================================================

locals {
  # -------------------------------------------------------------------------
  # Identificación del entorno
  # -------------------------------------------------------------------------
  environment = "staging"
  aws_region  = "eu-west-1"

  # IMPORTANTE: Reemplazar con el Account ID real de AWS antes de desplegar.
  # Staging puede estar en la misma cuenta que dev o en una cuenta separada.
  # Recomendación AWS: cuentas separadas por entorno (Organizations).
  account_id = "ACCOUNT_ID_PLACEHOLDER"

  # -------------------------------------------------------------------------
  # Configuración de ECS — API Service
  # -------------------------------------------------------------------------
  # Staging: 2 tasks para validar multi-AZ, pero menos que prod (4)
  api_desired_count = 2
  api_min_tasks     = 1
  api_max_tasks     = 8

  # CPU y memoria idénticos a prod para detectar problemas de sizing
  api_cpu    = 1024 # 1 vCPU — igual que prod
  api_memory = 2048 # 2 GB — igual que prod

  # -------------------------------------------------------------------------
  # Configuración de ECS — Workers
  # -------------------------------------------------------------------------
  worker_desired_count = 1
  worker_min_tasks     = 0
  worker_max_tasks     = 6

  # -------------------------------------------------------------------------
  # Networking
  # -------------------------------------------------------------------------
  # CIDR diferente al de dev y prod para evitar solapamiento en VPC Peering
  vpc_cidr = "10.2.0.0/16"

  # Staging usa 2 AZs (como mínimo) para detectar problemas multi-AZ
  availability_zones = ["eu-west-1a", "eu-west-1b"]

  # -------------------------------------------------------------------------
  # Fargate Capacity Providers
  # -------------------------------------------------------------------------
  # Staging: más Spot que prod para reducir coste, pero menos que dev
  # Una interrupción en staging es aceptable; permite probar el manejo de SIGTERM
  fargate_spot_weight      = 2 # ~67% Spot
  fargate_on_demand_weight = 1 # ~33% On-Demand

  # -------------------------------------------------------------------------
  # Observabilidad
  # -------------------------------------------------------------------------
  # Retención mayor que dev para poder investigar bugs que tardan en aparecer
  log_retention_days = 30

  # Container Insights en staging: activado para validar métricas antes de prod
  container_insights = true

  # -------------------------------------------------------------------------
  # Funcionalidades de staging
  # -------------------------------------------------------------------------
  # Sin scale-down nocturno en staging (debe estar disponible para QA)
  enable_scheduled_scaling = false
  scale_down_cron          = ""
  scale_up_cron            = ""

  # Protección de eliminación del ALB desactivada (permite destruir entorno)
  alb_deletion_protection = false
}
