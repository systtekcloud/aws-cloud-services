################################################################################
# Lab EC2 v2 — Outputs
################################################################################

output "aurora_writer_endpoint" {
  value       = aws_rds_cluster.aurora.endpoint
  description = "Writer endpoint de Aurora (para writes)"
}

output "aurora_reader_endpoint" {
  value       = aws_rds_cluster.aurora.reader_endpoint
  description = "Reader endpoint de Aurora (para reads)"
}

output "redis_primary_endpoint" {
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
  description = "Primary endpoint de Redis"
}

output "secret_aurora_arn" {
  value       = aws_secretsmanager_secret.aurora.arn
  description = "ARN del secret de Aurora (para políticas IAM)"
}

output "secret_redis_arn" {
  value       = aws_secretsmanager_secret.redis.arn
  description = "ARN del secret de Redis (para políticas IAM)"
}

output "db_subnet_ids" {
  value       = aws_subnet.db[*].id
  description = "IDs de subnets DB (reutilizar en v3)"
}

output "aurora_sg_id" {
  value       = aws_security_group.aurora.id
  description = "SG Aurora"
}

output "redis_sg_id" {
  value       = aws_security_group.redis.id
  description = "SG Redis"
}
