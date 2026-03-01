# ── Outputs — Lab v2: ECS Service + ALB ──────────────────────────────────────

output "vpc_id" {
  description = "ID de la VPC shopapi"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs de subnets públicas (ALB)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs de subnets privadas (ECS Tasks)"
  value       = aws_subnet.private[*].id
}

output "alb_dns_name" {
  description = "DNS del ALB — usar para hacer curl y verificar el lab"
  value       = aws_lb.main.dns_name
}

output "alb_arn" {
  description = "ARN del ALB"
  value       = aws_lb.main.arn
}

output "target_group_arn" {
  description = "ARN del Target Group donde se registran los ECS tasks"
  value       = aws_lb_target_group.api.arn
}

output "service_arn" {
  description = "ARN del ECS Service"
  value       = aws_ecs_service.api.id
}

output "alb_sg_id" {
  description = "Security Group del ALB (usado para SG chaining en tasks)"
  value       = aws_security_group.alb.id
}

output "task_sg_id" {
  description = "Security Group de los ECS Tasks"
  value       = aws_security_group.tasks.id
}

output "nat_gateway_id" {
  description = "ID del NAT Gateway (en v6 lo reemplazaremos con VPC Endpoints)"
  value       = aws_nat_gateway.main.id
}

# ── Comandos útiles para el lab ───────────────────────────────────────────────

output "cmd_test_api" {
  description = "Comando para probar el ALB"
  value       = "curl http://${aws_lb.main.dns_name}/health"
}

output "cmd_watch_service" {
  description = "Comando para monitorear el rolling update"
  value       = "watch -n5 'aws ecs describe-services --cluster shopapi-cluster --services shopapi-api --query \"services[0].deployments\" --output table'"
}
