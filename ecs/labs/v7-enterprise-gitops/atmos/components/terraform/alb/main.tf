# ── Componente Atmos: ALB ─────────────────────────────────────────────────────

module "alb" {
  source = "../../../../terragrunt/_modules/alb"

  environment           = var.environment
  vpc_id                = var.vpc_id
  public_subnet_ids     = var.public_subnet_ids
  deletion_protection   = var.deletion_protection
  health_check_path     = var.health_check_path
  health_check_interval = var.health_check_interval
  health_check_timeout  = var.health_check_timeout
  healthy_threshold     = var.healthy_threshold
  unhealthy_threshold   = var.unhealthy_threshold
  deregistration_delay  = var.deregistration_delay
  access_logs_enabled   = var.access_logs_enabled
  access_logs_bucket    = var.access_logs_bucket
  access_logs_prefix    = var.access_logs_prefix
}
