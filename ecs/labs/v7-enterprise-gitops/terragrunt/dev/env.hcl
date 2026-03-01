# =============================================================================
# Variables del Entorno: DEV
# =============================================================================
#
# Este archivo define todas las variables especificas del entorno de desarrollo.
# Es leido por el root terragrunt.hcl y por los modulos individuales.
#
# Principios del entorno dev:
#   - Minimo de recursos para reducir coste (1 task, sin workers)
#   - Maximo porcentaje de Fargate Spot (80%) para maximizar ahorro
#   - Una sola AZ (no es critico tener HA en dev)
#   - Retencion de logs corta (7 dias) para reducir costes de CloudWatch
#   - Sin Container Insights (coste adicional no justificado en dev)
#   - Scale-down nocturno: las tasks se reducen a 0 fuera del horario laboral
# =============================================================================

locals {
  # -------------------------------------------------------------------------
  # Identificacion del entorno
  # -------------------------------------------------------------------------
  environment = "dev"
  aws_region  = "eu-west-1"

  # IMPORTANTE: Reemplazar con el Account ID real de AWS antes de desplegar.
  # Para obtenerlo: aws sts get-caller-identity --query Account --output text
  account_id = "ACCOUNT_ID_PLACEHOLDER"

  # -------------------------------------------------------------------------
  # Configuracion de ECS — API Service
  # -------------------------------------------------------------------------
  # En dev se arranca 1 task para tener el servicio disponible durante
  # el horario de trabajo. El minimo es 1 (no 0) para que el servicio
  # responda inmediatamente sin cold start.
  api_desired_count = 1
  api_min_tasks     = 1
  api_max_tasks     = 5 # Permite escalar hasta 5 tasks si hay picos de carga

  # Configuracion de la Task Definition
  api_cpu    = 256  # 0.25 vCPU — suficiente para pruebas
  api_memory = 512  # 512 MB — minimo recomendado para FastAPI

  # -------------------------------------------------------------------------
  # Configuracion de ECS — Workers (procesos en background)
  # -------------------------------------------------------------------------
  # En dev no se necesitan workers (Celery, etc.) para ahorrar costes.
  # desired_count = 0 significa que el servicio existe pero sin tasks activas.
  worker_desired_count = 0
  worker_min_tasks     = 0
  worker_max_tasks     = 3

  # -------------------------------------------------------------------------
  # Networking
  # -------------------------------------------------------------------------
  # Cada entorno tiene su propio VPC CIDR para evitar solapamiento:
  #   dev:     10.1.0.0/16
  #   staging: 10.2.0.0/16
  #   prod:    10.0.0.0/16
  vpc_cidr = "10.1.0.0/16"

  # Dev usa una sola AZ para reducir costes (NAT Gateway x AZ tiene coste)
  availability_zones = ["eu-west-1a"]

  # -------------------------------------------------------------------------
  # Fargate Capacity Providers — Optimizacion de costes
  # -------------------------------------------------------------------------
  # Fargate Spot puede ser interrumpido por AWS, pero cuesta ~70% menos.
  # En dev, un reinicio ocasional es aceptable.
  #
  # El peso (weight) determina el ratio de tasks en Spot vs On-Demand:
  #   fargate_spot_weight = 4 y fargate_on_demand_weight = 1
  #   => 80% de las tasks iran a Spot, 20% a On-Demand
  fargate_spot_weight      = 4 # 80% Spot
  fargate_on_demand_weight = 1 # 20% On-Demand

  # -------------------------------------------------------------------------
  # Observabilidad
  # -------------------------------------------------------------------------
  # Retencion corta en dev para reducir costes de CloudWatch Logs
  log_retention_days = 7

  # Container Insights: metricas avanzadas de ECS (CPU, memoria por task)
  # Tiene coste adicional en CloudWatch, no justificado en dev
  container_insights = false

  # -------------------------------------------------------------------------
  # Funcionalidades especificas de dev
  # -------------------------------------------------------------------------
  # Scale-down nocturno: reduce las tasks a 0 fuera del horario laboral
  # usando EventBridge Scheduler. Ahorra ~60% del coste de EC2/Fargate en dev.
  enable_scheduled_scaling = true
  scale_down_cron          = "cron(0 20 * * ? *)"  # 20:00 UTC (21:00 CET)
  scale_up_cron            = "cron(0 7 * * ? *)"   # 07:00 UTC (08:00 CET)

  # Proteccion de eliminacion del ALB desactivada en dev
  alb_deletion_protection = false
}
