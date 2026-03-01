# ── Componente Atmos: ECS Cluster ─────────────────────────────────────────────

module "ecs_cluster" {
  source = "../../../../terragrunt/_modules/ecs-cluster"

  environment            = var.environment
  container_insights     = var.container_insights
  capacity_providers     = var.capacity_providers
  enable_execute_command = var.enable_execute_command
}
