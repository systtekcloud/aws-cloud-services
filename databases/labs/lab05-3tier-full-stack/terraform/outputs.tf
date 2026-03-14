# =============================================================================
# Lab05 — Outputs
# =============================================================================

# ─── VPC ──────────────────────────────────────────────────────────────────────
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "subnet_ids" {
  description = "Subnet IDs by tier"
  value = {
    public = [aws_subnet.public_a.id, aws_subnet.public_b.id]
    app    = [aws_subnet.app_a.id, aws_subnet.app_b.id]
    db     = [aws_subnet.db_a.id, aws_subnet.db_b.id]
  }
}

# ─── AURORA ───────────────────────────────────────────────────────────────────
output "aurora_cluster_endpoint" {
  description = "Aurora cluster writer endpoint"
  value       = aws_rds_cluster.aurora.endpoint
}

output "aurora_reader_endpoint" {
  description = "Aurora cluster reader endpoint (load-balanced)"
  value       = aws_rds_cluster.aurora.reader_endpoint
}

output "aurora_database_name" {
  description = "Aurora database name"
  value       = aws_rds_cluster.aurora.database_name
}

output "aurora_secret_arn" {
  description = "Secrets Manager ARN with Aurora credentials"
  value       = aws_secretsmanager_secret.aurora.arn
}

# ─── RDS PROXY ────────────────────────────────────────────────────────────────
output "rds_proxy_endpoint" {
  description = "RDS Proxy endpoint (use this in app instead of Aurora directly)"
  value       = aws_db_proxy.aurora.endpoint
}

# ─── DYNAMODB ─────────────────────────────────────────────────────────────────
output "dynamodb_table_name" {
  description = "DynamoDB catalog table name"
  value       = aws_dynamodb_table.catalog.name
}

output "dynamodb_table_stream_arn" {
  description = "DynamoDB Streams ARN"
  value       = aws_dynamodb_table.catalog.stream_arn
}

# ─── SNS ──────────────────────────────────────────────────────────────────────
output "sns_topic_arn" {
  description = "SNS topic ARN for order notifications"
  value       = aws_sns_topic.orders.arn
}

# ─── LAMBDA ───────────────────────────────────────────────────────────────────
output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.catalog_stream.function_name
}

output "lambda_function_arn" {
  description = "Lambda function ARN"
  value       = aws_lambda_function.catalog_stream.arn
}

# ─── REDIS ────────────────────────────────────────────────────────────────────
output "redis_primary_endpoint" {
  description = "Redis primary endpoint (writes)"
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "redis_reader_endpoint" {
  description = "Redis reader endpoint (load-balanced reads)"
  value       = aws_elasticache_replication_group.redis.reader_endpoint_address
}

# ─── CONEXIÓN ─────────────────────────────────────────────────────────────────
output "connection_commands" {
  description = "Commands to connect to each service from the app tier"
  value = <<-EOT
    # Aurora (via Proxy)
    mysql -h ${aws_db_proxy.aurora.endpoint} -P 3306 -u admin -p ${var.aurora_db_name}

    # Redis (TLS)
    redis-cli -h ${aws_elasticache_replication_group.redis.primary_endpoint_address} -p 6379 --tls PING

    # DynamoDB (via VPC Endpoint — no endpoint URL needed, uses gateway)
    aws dynamodb describe-table --table-name ${aws_dynamodb_table.catalog.name} --region ${var.aws_region}

    # Secret credentials
    aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.aurora.name} --region ${var.aws_region}
  EOT
}
