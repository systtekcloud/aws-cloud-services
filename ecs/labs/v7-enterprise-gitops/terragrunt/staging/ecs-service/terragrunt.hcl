# =============================================================================
# Módulo ECS Service — Entorno STAGING
# =============================================================================
#
# Staging es estructuralmente idéntico a prod, pero con:
#   - Menos tasks (2 vs 4)
#   - Más Fargate Spot (67% vs 0% en la API)
#   - Sin deletion protection
#   - Umbrales de alarma más relajados
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
    private_subnet_ids    = ["subnet-00000000000000001", "subnet-00000000000000002"]
    vpc_id                = "vpc-00000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "ecs_cluster" {
  config_path = "../ecs-cluster"

  mock_outputs = {
    cluster_arn  = "arn:aws:ecs:eu-west-1:123456789012:cluster/shopapi-cluster-staging-mock"
    cluster_name = "shopapi-cluster-staging-mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "alb" {
  config_path = "../alb"

  mock_outputs = {
    target_group_arn      = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:targetgroup/shopapi-staging-mock/abcdef123456"
    alb_dns_name          = "shopapi-staging-mock.eu-west-1.elb.amazonaws.com"
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

  # Imagen: en staging se validan los mismos artifacts que irán a prod
  # CI/CD sobreescribe este valor con la tag exacta del artifact
  container_image = "public.ecr.aws/shopapi/api:latest"
  container_port  = 8080
  cpu             = include.env.locals.api_cpu
  memory          = include.env.locals.api_memory

  desired_count = include.env.locals.api_desired_count
  min_tasks     = include.env.locals.api_min_tasks
  max_tasks     = include.env.locals.api_max_tasks

  # Staging: mezcla Spot/On-Demand para detectar problemas de interrupción
  # antes de llegar a prod. También reduce el coste del entorno.
  capacity_provider_strategy = [
    {
      capacity_provider = "FARGATE_SPOT"
      weight            = include.env.locals.fargate_spot_weight
      base              = 0
    },
    {
      capacity_provider = "FARGATE"
      weight            = include.env.locals.fargate_on_demand_weight
      base              = 1
    }
  ]

  log_retention_days = include.env.locals.log_retention_days

  # Umbrales de Auto Scaling (staging puede escalar más agresivamente)
  scale_up_cpu_threshold   = 60
  scale_down_cpu_threshold = 25

  # Sin scale-down nocturno en staging (QA trabaja en distintos horarios)
  enable_scheduled_scaling = include.env.locals.enable_scheduled_scaling
  scale_down_cron          = include.env.locals.scale_down_cron
  scale_up_cron            = include.env.locals.scale_up_cron
}
