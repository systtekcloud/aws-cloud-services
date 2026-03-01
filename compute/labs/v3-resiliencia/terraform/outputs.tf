output "tg_green_arn" {
  value       = aws_lb_target_group.green.arn
  description = "ARN del Target Group Green"
}

output "asg_green_name" {
  value       = aws_autoscaling_group.green.name
  description = "Nombre del ASG Green"
}

output "scale_out_policy_arn" {
  value       = aws_autoscaling_policy.step_scale_out.arn
  description = "ARN de la política de scale-out (Step Scaling)"
}

output "blue_green_commands" {
  description = "Comandos para gestionar el corte Blue/Green"
  value       = <<-EOT
    # Corte completo a Green (100%):
    aws elbv2 modify-listener --listener-arn ${var.alb_listener_arn} \
      --default-actions '[{"Type":"forward","ForwardConfig":{"TargetGroups":[{"TargetGroupArn":"${var.tg_blue_arn}","Weight":0},{"TargetGroupArn":"${aws_lb_target_group.green.arn}","Weight":100}]}}]'

    # Rollback a Blue (100%):
    aws elbv2 modify-listener --listener-arn ${var.alb_listener_arn} \
      --default-actions '[{"Type":"forward","TargetGroupArn":"${var.tg_blue_arn}"}]'
  EOT
}
