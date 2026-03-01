# ── Componente Atmos: ECS Service ────────────────────────────────────────────

module "ecs_service" {
  source = "../../../../terragrunt/_modules/ecs-service"

  environment                        = var.environment
  service_name                       = var.service_name
  cluster_name                       = var.cluster_name
  cluster_arn                        = var.cluster_arn
  vpc_id                             = var.vpc_id
  private_subnet_ids                 = var.private_subnet_ids
  target_group_arn                   = var.target_group_arn
  alb_security_group_id              = var.alb_security_group_id
  container_image                    = var.container_image
  container_port                     = var.container_port
  cpu                                = var.cpu
  memory                             = var.memory
  desired_count                      = var.desired_count
  min_tasks                          = var.min_tasks
  max_tasks                          = var.max_tasks
  capacity_provider_strategy         = var.capacity_provider_strategy
  log_retention_days                 = var.log_retention_days
  scale_up_cpu_threshold             = var.scale_up_cpu_threshold
  scale_down_cpu_threshold           = var.scale_down_cpu_threshold
  enable_scheduled_scaling           = var.enable_scheduled_scaling
  scale_down_cron                    = var.scale_down_cron
  scale_up_cron                      = var.scale_up_cron
  ops_email                          = var.ops_email
  alarm_5xx_threshold                = var.alarm_5xx_threshold
  alarm_latency_p99_seconds          = var.alarm_latency_p99_seconds
  deployment_circuit_breaker_enabled  = var.deployment_circuit_breaker_enabled
  deployment_circuit_breaker_rollback = var.deployment_circuit_breaker_rollback
  deployment_maximum_percent         = var.deployment_maximum_percent
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
}
