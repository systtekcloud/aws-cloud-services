# =============================================================================
# Módulo ECS Cluster — Entorno PROD
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

  # Container Insights obligatorio en prod: métricas por task para alertas
  container_insights = include.env.locals.container_insights

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  # Execute Command: permite conectar a tasks para debugging en emergencias
  # Requiere task role con permisos SSM
  enable_execute_command = true
}
