# =============================================================================
# Variables del Entorno: PROD
# =============================================================================
#
# Producción: máxima disponibilidad, mínima tolerancia a fallos.
#   - Alta disponibilidad: 3 AZs, mínimo 2 tasks siempre corriendo
#   - Mínimo Fargate Spot (solo workers toleran interrupciones)
#   - Retención de logs 90 días (auditoría y cumplimiento normativo)
#   - Container Insights activado (visibilidad completa)
#   - ALB Deletion Protection: evita borrado accidental
#   - Sin scale-down nocturno (servicio 24/7)
#
# Nota sobre Savings Plans:
#   Con 4+ tasks corriendo 24/7, un 1-year Compute Savings Plan
#   puede añadir un 17% de descuento adicional sobre el precio ARM64.
# =============================================================================

locals {
  # -------------------------------------------------------------------------
  # Identificación del entorno
  # -------------------------------------------------------------------------
  environment = "prod"
  aws_region  = "eu-west-1"

  # IMPORTANTE: Reemplazar con el Account ID real de AWS antes de desplegar.
  # Producción DEBE estar en una cuenta AWS separada (AWS Organizations).
  # Esto limita el blast radius de un incidente o error humano.
  account_id = "ACCOUNT_ID_PLACEHOLDER"

  # -------------------------------------------------------------------------
  # Configuración de ECS — API Service
  # -------------------------------------------------------------------------
  # Prod: 4 tasks en 3 AZs para alta disponibilidad
  # Con rolling update (maximumPercent=200, minimumHealthyPercent=100),
  # un deploy nunca baja de 4 tasks activas
  api_desired_count = 4
  api_min_tasks     = 2  # Mínimo absoluto: nunca menos de 2 tasks corriendo
  api_max_tasks     = 20 # Capacidad de escalar en picos (Black Friday, etc.)

  # CPU y memoria para producción real
  api_cpu    = 1024 # 1 vCPU
  api_memory = 2048 # 2 GB

  # -------------------------------------------------------------------------
  # Configuración de ECS — Workers
  # -------------------------------------------------------------------------
  worker_desired_count = 2
  worker_min_tasks     = 1  # Siempre al menos 1 worker procesando mensajes
  worker_max_tasks     = 20 # Escala agresivamente con la profundidad de SQS

  # -------------------------------------------------------------------------
  # Networking
  # -------------------------------------------------------------------------
  # CIDR de prod: el bloque /16 "primario" (10.0.0.0/16)
  vpc_cidr = "10.0.0.0/16"

  # Prod: 3 AZs para cumplir SLA de disponibilidad del 99.9%
  # Una AZ puede caer completamente sin impacto en el servicio
  availability_zones = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]

  # -------------------------------------------------------------------------
  # Fargate Capacity Providers
  # -------------------------------------------------------------------------
  # API: FARGATE puro (cero tolerancia a interrupciones)
  # Workers: mayoría SPOT (coste) con base FARGATE garantizada
  fargate_spot_weight      = 0 # API: 0% Spot — solo FARGATE On-Demand
  fargate_on_demand_weight = 1 # 100% On-Demand para la API

  # Workers tienen su propia configuración en ecs-service de worker (ver inputs)
  worker_spot_weight      = 3 # ~75% Spot para workers
  worker_on_demand_weight = 1 # ~25% On-Demand para workers

  # -------------------------------------------------------------------------
  # Observabilidad
  # -------------------------------------------------------------------------
  # 90 días: retención recomendada para auditoría y análisis de incidentes
  # Ajustar según requisitos de compliance (PCI-DSS: 12 meses, HIPAA: 6 años)
  log_retention_days = 90

  # Container Insights obligatorio en prod: métricas CPU/memoria por task
  container_insights = true

  # -------------------------------------------------------------------------
  # Funcionalidades de prod
  # -------------------------------------------------------------------------
  # Sin scale-down: el servicio es 24/7
  enable_scheduled_scaling = false
  scale_down_cron          = ""
  scale_up_cron            = ""

  # Protección contra eliminación accidental del ALB
  alb_deletion_protection = true

  # -------------------------------------------------------------------------
  # Alertas y alarmas (solo prod)
  # -------------------------------------------------------------------------
  # Email del equipo de operaciones para recibir alarmas de CloudWatch
  ops_email = "ops-team@shopapi.com"

  # Umbrales de alarma más estrictos que en staging
  alarm_5xx_threshold       = 1    # 1% de errores dispara alarma
  alarm_latency_p99_seconds = 0.5  # 500ms P99 máximo
}
