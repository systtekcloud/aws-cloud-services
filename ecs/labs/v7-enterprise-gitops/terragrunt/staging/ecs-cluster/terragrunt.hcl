# =============================================================================
# Módulo ECS Cluster — Entorno STAGING
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
  environment = include.env.locals.environment

  # Container Insights activado en staging para validar métricas antes de prod
  container_insights = include.env.locals.container_insights

  # Capacity Providers disponibles en el cluster
  # Los servicios eligen entre estos según su estrategia
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}
