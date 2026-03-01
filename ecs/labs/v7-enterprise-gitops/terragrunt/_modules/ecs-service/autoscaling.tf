# ── Application Auto Scaling — ECS Service ───────────────────────────────────
# Target Tracking: mantiene el CPU en el umbral definido, escalando/reduciendo tasks.
# Scale-down programado: reduce a 0 tasks en horas nocturnas (solo dev).

resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.max_tasks
  min_capacity       = var.min_tasks
  resource_id        = "service/${var.cluster_name}/${var.service_name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = [aws_ecs_service.api]
}

# ── Target Tracking: CPU ──────────────────────────────────────────────────────
# ECS añade tasks cuando el CPU promedio supera el umbral (scale-out cooldown: 60s).
# ECS elimina tasks cuando el CPU baja del umbral (scale-in cooldown: 300s).
# El cooldown de scale-in largo evita oscilaciones (thrashing).

resource "aws_appautoscaling_policy" "cpu" {
  name               = "shopapi-scale-cpu-${var.environment}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.scale_up_cpu_threshold
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

# ── Scale-down nocturno (solo dev) ────────────────────────────────────────────
# Reduce las tasks a 0 fuera del horario laboral para ahorrar coste.
# Solo se activa con enable_scheduled_scaling = true.

resource "aws_appautoscaling_scheduled_action" "scale_down" {
  count = var.enable_scheduled_scaling ? 1 : 0

  name               = "shopapi-scale-down-${var.environment}"
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  schedule           = var.scale_down_cron

  scalable_target_action {
    min_capacity = 0
    max_capacity = 1
  }
}

resource "aws_appautoscaling_scheduled_action" "scale_up" {
  count = var.enable_scheduled_scaling ? 1 : 0

  name               = "shopapi-scale-up-${var.environment}"
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  schedule           = var.scale_up_cron

  scalable_target_action {
    min_capacity = var.min_tasks
    max_capacity = var.max_tasks
  }
}
