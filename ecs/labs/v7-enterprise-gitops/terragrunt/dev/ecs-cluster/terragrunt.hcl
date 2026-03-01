# =============================================================================
# Modulo ECS Cluster — Entorno DEV
# =============================================================================

terraform {
  source = "../../../_modules//ecs-cluster"
}

include "root" {
  path = find_in_parent_folders()
}

include "env" {
  path   = find_in_parent_folders("env.hcl")
  expose = true
}

inputs = {
  environment  = include.env.locals.environment
  cluster_name = "shopapi-cluster-${include.env.locals.environment}"

  # Container Insights: metricas avanzadas (CPU/memoria por task, red, etc.)
  # Tiene un coste adicional en CloudWatch (~0.35 USD por 1000 metricas).
  # En dev se desactiva para ahorrar costes; en staging y prod se activa.
  container_insights = include.env.locals.container_insights

  # Capacity Providers: definir la mezcla de Fargate Spot vs On-Demand
  # Estos providers se configuran a nivel de cluster y luego cada servicio
  # define su estrategia (como se configuran en ecs-service)
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  # Configuracion por defecto del cluster: 100% On-Demand como fallback
  # Los servicios individuales pueden sobreescribir esta configuracion
  default_capacity_provider_strategy = [
    {
      capacity_provider = "FARGATE"
      weight            = 1
      base              = 0
    }
  ]
}
