terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      Lab       = var.lab
      Env       = var.env
      ManagedBy = "terraform"
    }
  }
}

# ---------------------------------------------------------------------------
# Data sources — VPC compartida con lab01
# ---------------------------------------------------------------------------

data "aws_vpc" "lab" {
  cidr_block = var.vpc_cidr
  tags       = { Project = var.project }
}

data "aws_subnet" "private_a" {
  vpc_id            = data.aws_vpc.lab.id
  cidr_block        = var.subnet_private_a_cidr
  availability_zone = var.az_a
}

data "aws_subnet" "private_b" {
  vpc_id            = data.aws_vpc.lab.id
  cidr_block        = var.subnet_private_b_cidr
  availability_zone = var.az_b
}

data "aws_security_group" "app" {
  name   = "sg-app-db-labs"
  vpc_id = data.aws_vpc.lab.id
}

# ---------------------------------------------------------------------------
# Security Group
# ---------------------------------------------------------------------------

resource "aws_security_group" "redis" {
  name        = "sg-redis-db-labs"
  description = "ElastiCache Redis lab04 — inbound from sg-app only"
  vpc_id      = data.aws_vpc.lab.id

  ingress {
    description     = "Redis from app tier"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [data.aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------------------
# Cache Subnet Group
# ---------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "redis" {
  name        = var.redis_subnet_group
  description = "Redis subnets — private only, 2 AZs"
  subnet_ids  = [data.aws_subnet.private_a.id, data.aws_subnet.private_b.id]
}

# ---------------------------------------------------------------------------
# Replication Group
# ---------------------------------------------------------------------------

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = var.redis_cluster_id
  description          = "Redis lab04 — cache aside y session store"

  engine               = "redis"
  engine_version       = var.redis_engine_version
  node_type            = var.redis_node_type
  num_cache_clusters   = var.redis_num_clusters
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.redis.id]

  automatic_failover_enabled = var.enable_multi_az
  multi_az_enabled           = var.enable_multi_az

  at_rest_encryption_enabled = var.at_rest_encryption
  transit_encryption_enabled = var.transit_encryption

  snapshot_retention_limit = var.snapshot_retention

  # Lab: no protección de borrado
  apply_immediately = true
}

# ---------------------------------------------------------------------------
# CloudWatch Alarms
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "cache_hits" {
  alarm_name          = "redis-lab-low-hit-rate"
  alarm_description   = "Redis Hit Rate por debajo del 80%"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  threshold           = 80
  period              = 300
  statistic           = "Average"

  metric_name = "CacheHitRate"
  namespace   = "AWS/ElastiCache"

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.redis.id
  }
}

resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "redis-lab-memory-high"
  alarm_description   = "Redis Freeable Memory < 100MB"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  threshold           = 100000000  # 100 MB en bytes
  period              = 300
  statistic           = "Average"

  metric_name = "FreeableMemory"
  namespace   = "AWS/ElastiCache"

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.redis.id
  }
}
