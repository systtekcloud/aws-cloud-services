output "secret_arn" {
  description = "ARN del secret en Secrets Manager"
  value       = aws_secretsmanager_secret.db.arn
}

output "task_role_arn" {
  description = "ARN del Task Role de la aplicación"
  value       = aws_iam_role.task.arn
}

output "sns_topic_arn" {
  description = "ARN del SNS topic de alertas"
  value       = aws_sns_topic.alerts.arn
}

output "task_definition_arn" {
  description = "ARN de la nueva Task Definition con secrets"
  value       = aws_ecs_task_definition.api_v3.arn
}

output "log_group_name" {
  description = "Nombre del CloudWatch Log Group"
  value       = aws_cloudwatch_log_group.ecs.name
}

output "cmd_get_secret" {
  description = "Comando para ver el valor del secret"
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.db.name} --query SecretString --output text | python3 -m json.tool"
}
