output "alb_arn" {
  description = "ARN del Application Load Balancer"
  value       = aws_lb.main.arn
}

output "alb_dns_name" {
  description = "DNS name del ALB para acceder a la aplicación"
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Hosted Zone ID del ALB (para Route 53 alias records)"
  value       = aws_lb.main.zone_id
}

output "alb_arn_suffix" {
  description = "ARN suffix del ALB para métricas de CloudWatch"
  value       = aws_lb.main.arn_suffix
}

output "target_group_arn" {
  description = "ARN del Target Group — necesario para el ECS Service"
  value       = aws_lb_target_group.api.arn
}

output "target_group_arn_suffix" {
  description = "ARN suffix del Target Group para métricas de CloudWatch"
  value       = aws_lb_target_group.api.arn_suffix
}

output "alb_security_group_id" {
  description = "ID del Security Group del ALB — necesario para el SG de las tasks ECS"
  value       = aws_security_group.alb.id
}

output "listener_arn" {
  description = "ARN del Listener HTTP del ALB"
  value       = aws_lb_listener.http.arn
}
