output "redis_primary_endpoint" {
  description = "Redis Primary endpoint — use for writes"
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "redis_reader_endpoint" {
  description = "Redis Reader endpoint — load balances reads across replicas"
  value       = aws_elasticache_replication_group.redis.reader_endpoint_address
}

output "redis_port" {
  description = "Redis port"
  value       = aws_elasticache_replication_group.redis.port
}

output "redis_cluster_id" {
  description = "Replication Group ID"
  value       = aws_elasticache_replication_group.redis.id
}

output "redis_engine_version" {
  description = "Redis engine version"
  value       = aws_elasticache_replication_group.redis.engine_version_actual
}

output "security_group_id" {
  description = "Redis Security Group ID"
  value       = aws_security_group.redis.id
}

output "subnet_group_name" {
  description = "Cache Subnet Group name"
  value       = aws_elasticache_subnet_group.redis.name
}

output "multi_az_enabled" {
  description = "Whether Multi-AZ is enabled"
  value       = var.enable_multi_az
}

output "connect_commands" {
  description = "Commands to connect from EC2 via SSM"
  value = {
    install   = "sudo apt-get install -y redis-tools"
    ping      = "redis-cli -h ${aws_elasticache_replication_group.redis.primary_endpoint_address} -p 6379 --tls PING"
    set_key   = "redis-cli -h ${aws_elasticache_replication_group.redis.primary_endpoint_address} -p 6379 --tls SET mykey myvalue EX 300"
    get_key   = "redis-cli -h ${aws_elasticache_replication_group.redis.primary_endpoint_address} -p 6379 --tls GET mykey"
    info_repl = "redis-cli -h ${aws_elasticache_replication_group.redis.primary_endpoint_address} -p 6379 --tls INFO replication"
  }
}
