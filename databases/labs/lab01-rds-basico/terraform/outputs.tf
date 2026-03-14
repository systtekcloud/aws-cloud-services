output "vpc_id" {
  description = "ID de la VPC del lab"
  value       = aws_vpc.main.id
}

output "private_db_subnet_ids" {
  description = "IDs de las subnets privadas de DB"
  value       = [aws_subnet.private_db_a.id, aws_subnet.private_db_b.id]
}

output "rds_endpoint" {
  description = "Endpoint de conexión RDS (hostname)"
  value       = aws_db_instance.main.address
}

output "rds_port" {
  description = "Puerto de conexión RDS"
  value       = aws_db_instance.main.port
}

output "rds_db_name" {
  description = "Nombre de la base de datos"
  value       = aws_db_instance.main.db_name
}

output "rds_replica_endpoint" {
  description = "Endpoint de la Read Replica (si está habilitada)"
  value       = var.enable_read_replica ? aws_db_instance.replica[0].address : null
}

output "secrets_manager_arn" {
  description = "ARN del secreto en Secrets Manager"
  value       = aws_secretsmanager_secret.rds_credentials.arn
}

output "kms_key_arn" {
  description = "ARN de la KMS CMK"
  value       = aws_kms_key.rds.arn
}

output "kms_key_alias" {
  description = "Alias de la KMS CMK"
  value       = aws_kms_alias.rds.name
}

output "ec2_instance_id" {
  description = "ID de la instancia EC2 app (para SSM Session Manager)"
  value       = aws_instance.app.id
}

output "ec2_ssm_connect_command" {
  description = "Comando para conectar via SSM Session Manager"
  value       = "aws ssm start-session --target ${aws_instance.app.id} --region ${var.aws_region}"
}

output "sg_rds_id" {
  description = "ID del Security Group de RDS"
  value       = aws_security_group.rds.id
}

output "sns_alerts_arn" {
  description = "ARN del SNS Topic de alertas RDS"
  value       = aws_sns_topic.rds_alerts.arn
}
