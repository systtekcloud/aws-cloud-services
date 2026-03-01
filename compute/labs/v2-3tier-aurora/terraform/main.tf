################################################################################
# Lab EC2 v2 — Terraform
# Añade a v1: Aurora MySQL Multi-AZ + ElastiCache Redis + Secrets Manager
#
# Prerequisito: v1 desplegado. Importar outputs de v1 como variables.
################################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Lab         = "v2"
      ManagedBy   = "Terraform"
      Environment = var.environment
    }
  }
}

################################################################################
# Data Sources
################################################################################

data "aws_availability_zones" "available" { state = "available" }

data "aws_caller_identity" "current" {}

data "aws_vpc" "main" { id = var.vpc_id }

# AZs de las subnets de app (v1)
data "aws_subnet" "app" {
  count = length(var.private_app_subnet_ids)
  id    = var.private_app_subnet_ids[count.index]
}

# Route table privada (para asociar subnets DB)
data "aws_route_tables" "private" {
  vpc_id = var.vpc_id
  filter {
    name   = "tag:Lab"
    values = ["v1"]
  }
}

################################################################################
# Locals
################################################################################

locals {
  name_prefix = "${var.project}-${var.environment}"
  azs         = data.aws_subnet.app[*].availability_zone

  db_password    = random_password.db.result
  redis_token    = random_password.redis.result
  db_subnet_arns = aws_subnet.db[*].id
}

################################################################################
# Passwords aleatorios (Terraform los gestiona; van a Secrets Manager)
################################################################################

resource "random_password" "db" {
  length  = 24
  special = false
}

resource "random_password" "redis" {
  length  = 32
  special = false
}

################################################################################
# Subnets de base de datos
################################################################################

resource "aws_subnet" "db" {
  count = length(local.azs)

  vpc_id            = var.vpc_id
  cidr_block        = var.db_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${local.name_prefix}-db-${local.azs[count.index]}" }
}

# Asociar subnets DB a las route tables privadas de v1
resource "aws_route_table_association" "db" {
  count = length(local.azs)

  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = tolist(data.aws_route_tables.private.ids)[min(count.index, length(data.aws_route_tables.private.ids) - 1)]
}

################################################################################
# Security Groups
################################################################################

resource "aws_security_group" "aurora" {
  name        = "${local.name_prefix}-sg-aurora"
  description = "Aurora — solo desde EC2 SG"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [var.ec2_sg_id]
  }

  tags = { Name = "${local.name_prefix}-sg-aurora" }
}

resource "aws_security_group" "redis" {
  name        = "${local.name_prefix}-sg-redis"
  description = "Redis — solo desde EC2 SG"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.ec2_sg_id]
  }

  tags = { Name = "${local.name_prefix}-sg-redis" }
}

################################################################################
# Aurora MySQL Multi-AZ
################################################################################

resource "aws_db_subnet_group" "aurora" {
  name        = "${local.name_prefix}-aurora-subnet-group"
  description = "Aurora Multi-AZ subnet group"
  subnet_ids  = aws_subnet.db[*].id
}

resource "aws_rds_cluster" "aurora" {
  cluster_identifier     = "${local.name_prefix}-aurora-cluster"
  engine                 = "aurora-mysql"
  engine_version         = var.aurora_engine_version
  master_username        = "admin"
  master_password        = local.db_password
  database_name          = var.db_name
  db_subnet_group_name   = aws_db_subnet_group.aurora.name
  vpc_security_group_ids = [aws_security_group.aurora.id]
  skip_final_snapshot    = true # en labs
  storage_encrypted      = true
  backup_retention_period = 1
}

resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${local.name_prefix}-aurora-writer"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = var.db_instance_class
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version
}

resource "aws_rds_cluster_instance" "reader" {
  identifier         = "${local.name_prefix}-aurora-reader"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = var.db_instance_class
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version
}

################################################################################
# ElastiCache Redis
################################################################################

resource "aws_elasticache_subnet_group" "redis" {
  name       = "${local.name_prefix}-redis-subnet-group"
  subnet_ids = aws_subnet.db[*].id
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${local.name_prefix}-redis"
  description          = "Redis con in-transit encryption"
  node_type            = var.redis_node_type
  num_cache_clusters   = var.redis_num_clusters
  engine_version       = "7.1"

  subnet_group_name          = aws_elasticache_subnet_group.redis.name
  security_group_ids         = [aws_security_group.redis.id]
  transit_encryption_enabled = true
  auth_token                 = local.redis_token
  automatic_failover_enabled = var.redis_num_clusters > 1
  multi_az_enabled           = var.redis_num_clusters > 1

  at_rest_encryption_enabled = true
}

################################################################################
# Secrets Manager
################################################################################

resource "aws_secretsmanager_secret" "aurora" {
  name                    = "${local.name_prefix}/aurora/credentials"
  description             = "Aurora MySQL credentials"
  recovery_window_in_days = 0 # borrado inmediato en labs
}

resource "aws_secretsmanager_secret_version" "aurora" {
  secret_id = aws_secretsmanager_secret.aurora.id
  secret_string = jsonencode({
    username = "admin"
    password = local.db_password
    host     = aws_rds_cluster.aurora.endpoint
    reader   = aws_rds_cluster.aurora.reader_endpoint
    dbname   = var.db_name
    port     = 3306
  })
}

resource "aws_secretsmanager_secret" "redis" {
  name                    = "${local.name_prefix}/redis/auth-token"
  description             = "Redis auth token"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "redis" {
  secret_id = aws_secretsmanager_secret.redis.id
  secret_string = jsonencode({
    auth_token = local.redis_token
    endpoint   = aws_elasticache_replication_group.redis.primary_endpoint_address
  })
}
