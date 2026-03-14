output "aurora_cluster_id" {
  description = "Aurora cluster identifier"
  value       = aws_rds_cluster.aurora.cluster_identifier
}

output "aurora_writer_endpoint" {
  description = "Cluster (Writer) endpoint — use for INSERT/UPDATE/DELETE"
  value       = aws_rds_cluster.aurora.endpoint
}

output "aurora_reader_endpoint" {
  description = "Reader endpoint (load balancer) — use for SELECT"
  value       = aws_rds_cluster.aurora.reader_endpoint
}

output "aurora_port" {
  description = "Aurora MySQL port"
  value       = aws_rds_cluster.aurora.port
}

output "aurora_database_name" {
  description = "Initial database name"
  value       = aws_rds_cluster.aurora.database_name
}

output "aurora_writer_instance" {
  description = "Writer instance identifier"
  value       = aws_rds_cluster_instance.writer.id
}

output "aurora_reader_instance" {
  description = "Reader instance identifier (null if disabled)"
  value       = var.enable_reader ? aws_rds_cluster_instance.reader[0].id : null
}

output "secret_arn" {
  description = "Secrets Manager ARN with Aurora credentials"
  value       = aws_secretsmanager_secret.aurora.arn
}

output "kms_key_arn" {
  description = "KMS key used for Aurora storage encryption"
  value       = local.kms_key_arn
}

output "security_group_id" {
  description = "Aurora Security Group ID"
  value       = aws_security_group.aurora.id
}

output "db_subnet_group" {
  description = "DB Subnet Group name"
  value       = aws_db_subnet_group.aurora.name
}

output "backtrack_window" {
  description = "Backtrack window in seconds"
  value       = aws_rds_cluster.aurora.backtrack_window
}

output "sns_alerts_arn" {
  description = "SNS topic ARN for CloudWatch alerts"
  value       = aws_sns_topic.alerts.arn
}

output "connect_commands" {
  description = "Commands to connect from EC2 via SSM"
  value = {
    get_password = "aws secretsmanager get-secret-value --secret-id ${var.secret_id} --query SecretString --output text | jq -r '.password'"
    writer       = "mysql -h ${aws_rds_cluster.aurora.endpoint} -u ${var.aurora_master_user} -p'$PASS' ${var.aurora_db_name}"
    reader       = "mysql -h ${aws_rds_cluster.aurora.reader_endpoint} -u ${var.aurora_master_user} -p'$PASS' ${var.aurora_db_name}"
  }
}
