output "service_name" {
  description = "Nombre del servicio ECS"
  value       = aws_ecs_service.api.name
}

output "service_arn" {
  description = "ARN del servicio ECS"
  value       = aws_ecs_service.api.id
}

output "task_definition_arn" {
  description = "ARN de la Task Definition activa"
  value       = aws_ecs_task_definition.api.arn
}

output "task_definition_family" {
  description = "Family de la Task Definition"
  value       = aws_ecs_task_definition.api.family
}

output "security_group_id" {
  description = "ID del Security Group de las tasks ECS"
  value       = aws_security_group.ecs_tasks.id
}

output "execution_role_arn" {
  description = "ARN del Execution Role"
  value       = aws_iam_role.execution.arn
}

output "task_role_arn" {
  description = "ARN del Task Role"
  value       = aws_iam_role.task.arn
}

output "log_group_name" {
  description = "Nombre del CloudWatch Log Group"
  value       = aws_cloudwatch_log_group.ecs.name
}

output "sns_topic_arn" {
  description = "ARN del SNS Topic de alarmas (vacío si ops_email no está configurado)"
  value       = var.ops_email != "" ? aws_sns_topic.alerts[0].arn : ""
}
