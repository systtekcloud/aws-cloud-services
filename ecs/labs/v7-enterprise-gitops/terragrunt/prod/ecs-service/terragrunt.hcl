# =============================================================================
# Módulo ECS Service — Entorno PROD
# =============================================================================
#
# Configuración de producción: máxima disponibilidad y resiliencia.
#   - 4 tasks en 3 AZs
#   - FARGATE puro para la API (sin interrupciones)
#   - Circuit Breaker con rollback automático
#   - Deployment Controller CodeDeploy para Blue/Green (opcional)
# =============================================================================

terraform {
  source = "../../../_modules//ecs-service"
}

include "root" {
  path = find_in_parent_folders()
}

include "env" {
  path   = find_in_parent_folders("env.hcl")
  expose = true
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    private_subnet_ids    = ["subnet-00000000000000001", "subnet-00000000000000002", "subnet-00000000000000003"]
    vpc_id                = "vpc-00000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "ecs_cluster" {
  config_path = "../ecs-cluster"

  mock_outputs = {
    cluster_arn  = "arn:aws:ecs:eu-west-1:123456789012:cluster/shopapi-cluster-prod-mock"
    cluster_name = "shopapi-cluster-prod-mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "alb" {
  config_path = "../alb"

  mock_outputs = {
    target_group_arn      = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:targetgroup/shopapi-prod-mock/abcdef123456"
    alb_dns_name          = "shopapi-prod.eu-west-1.elb.amazonaws.com"
    alb_security_group_id = "sg-00000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  environment  = include.env.locals.environment
  service_name = "shopapi-api"

  cluster_name = dependency.ecs_cluster.outputs.cluster_name
  cluster_arn  = dependency.ecs_cluster.outputs.cluster_arn

  vpc_id             = dependency.vpc.outputs.vpc_id
  private_subnet_ids = dependency.vpc.outputs.private_subnet_ids

  target_group_arn      = dependency.alb.outputs.target_group_arn
  alb_security_group_id = dependency.alb.outputs.alb_security_group_id

  # Imagen: CI/CD sobreescribe con la tag exacta del artifact validado en staging
  container_image = "public.ecr.aws/shopapi/api:latest"
  container_port  = 8080
  cpu             = include.env.locals.api_cpu
  memory          = include.env.locals.api_memory

  desired_count = include.env.locals.api_desired_count
  min_tasks     = include.env.locals.api_min_tasks
  max_tasks     = include.env.locals.api_max_tasks

  # Prod API: FARGATE puro — cero tolerancia a interrupciones por Spot
  # Los workers sí pueden usar Spot (configurados en módulo separado)
  capacity_provider_strategy = [
    {
      capacity_provider = "FARGATE"
      base              = include.env.locals.api_desired_count
      weight            = 1
    }
  ]

  log_retention_days = include.env.locals.log_retention_days

  # Auto Scaling conservador en prod: escala cuando CPU supera 50%
  # Umbral más bajo que staging para reaccionar antes de saturar
  scale_up_cpu_threshold   = 50
  scale_down_cpu_threshold = 20

  # Sin scale-down programado en prod: servicio 24/7
  enable_scheduled_scaling = include.env.locals.enable_scheduled_scaling
  scale_down_cron          = include.env.locals.scale_down_cron
  scale_up_cron            = include.env.locals.scale_up_cron

  # Alarmas de CloudWatch más estrictas en prod
  ops_email                 = include.env.locals.ops_email
  alarm_5xx_threshold       = include.env.locals.alarm_5xx_threshold
  alarm_latency_p99_seconds = include.env.locals.alarm_latency_p99_seconds
}
