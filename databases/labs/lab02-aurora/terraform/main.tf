terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project    = var.project
      Lab        = var.lab
      Env        = var.env
      ManagedBy  = "terraform"
    }
  }
}

# ---------------------------------------------------------------------------
# Data sources — VPC compartida con lab01
# ---------------------------------------------------------------------------

data "aws_vpc" "lab" {
  cidr_block = var.vpc_cidr

  tags = {
    Project = var.project
  }
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
# KMS — usar CMK si se proporciona, sino usar key gestionada por AWS
# ---------------------------------------------------------------------------

data "aws_kms_key" "rds" {
  count  = var.kms_key_arn == "" ? 1 : 0
  key_id = "alias/aws/rds"
}

locals {
  kms_key_arn = var.kms_key_arn != "" ? var.kms_key_arn : data.aws_kms_key.rds[0].arn
}

# ---------------------------------------------------------------------------
# Security Group para Aurora
# ---------------------------------------------------------------------------

resource "aws_security_group" "aurora" {
  name        = "sg-aurora-db-labs"
  description = "Aurora MySQL lab02 — inbound from sg-app only"
  vpc_id      = data.aws_vpc.lab.id

  ingress {
    description     = "MySQL from app tier"
    from_port       = 3306
    to_port         = 3306
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
# DB Subnet Group
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "aurora" {
  name        = var.aurora_subnet_group
  description = "Aurora subnets — private only, 2 AZs"
  subnet_ids  = [data.aws_subnet.private_a.id, data.aws_subnet.private_b.id]
}

# ---------------------------------------------------------------------------
# Credenciales en Secrets Manager
# ---------------------------------------------------------------------------

resource "random_password" "aurora" {
  length           = 20
  special          = false
  override_special = ""
}

resource "aws_secretsmanager_secret" "aurora" {
  name        = var.secret_id
  description = "Aurora MySQL admin credentials for lab02"

  recovery_window_in_days = 0  # permite eliminación inmediata en cleanup
}

resource "aws_secretsmanager_secret_version" "aurora" {
  secret_id = aws_secretsmanager_secret.aurora.id

  secret_string = jsonencode({
    username    = var.aurora_master_user
    password    = random_password.aurora.result
    writer_host = aws_rds_cluster.aurora.endpoint
    reader_host = aws_rds_cluster.aurora.reader_endpoint
    port        = 3306
    dbname      = var.aurora_db_name
  })
}

# ---------------------------------------------------------------------------
# Aurora DB Cluster
# ---------------------------------------------------------------------------

resource "aws_rds_cluster" "aurora" {
  cluster_identifier = var.aurora_cluster_id
  engine             = var.aurora_engine
  engine_version     = var.aurora_engine_version

  master_username = var.aurora_master_user
  master_password = random_password.aurora.result

  database_name            = var.aurora_db_name
  db_subnet_group_name     = aws_db_subnet_group.aurora.name
  vpc_security_group_ids   = [aws_security_group.aurora.id]

  backup_retention_period  = var.backup_retention_days
  preferred_backup_window  = "03:00-04:00"
  storage_encrypted        = true
  kms_key_id               = local.kms_key_arn

  # Backtrack (Aurora MySQL only)
  backtrack_window         = var.aurora_engine == "aurora-mysql" ? var.backtrack_window : 0

  deletion_protection      = var.enable_deletion_protection
  skip_final_snapshot      = true  # lab: no snapshot al destruir

  enabled_cloudwatch_logs_exports = ["error", "general", "slowquery"]
}

# ---------------------------------------------------------------------------
# Aurora Writer Instance
# ---------------------------------------------------------------------------

resource "aws_rds_cluster_instance" "writer" {
  identifier         = var.aurora_writer_id
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = var.aurora_instance_class
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version

  availability_zone       = var.az_a
  publicly_accessible     = false
  promotion_tier          = 1  # writer: tier medio (el reader tiene 0)
  monitoring_interval     = 60
  monitoring_role_arn     = aws_iam_role.rds_enhanced_monitoring.arn

  auto_minor_version_upgrade = false
}

# ---------------------------------------------------------------------------
# Aurora Reader Instance (opcional)
# ---------------------------------------------------------------------------

resource "aws_rds_cluster_instance" "reader" {
  count = var.enable_reader ? 1 : 0

  identifier         = var.aurora_reader_id
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = var.aurora_instance_class
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version

  availability_zone       = var.az_b
  publicly_accessible     = false
  promotion_tier          = var.reader_promotion_tier  # 0 = alta prioridad failover
  monitoring_interval     = 60
  monitoring_role_arn     = aws_iam_role.rds_enhanced_monitoring.arn

  auto_minor_version_upgrade = false
}

# ---------------------------------------------------------------------------
# IAM Role para Enhanced Monitoring
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "rds_monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_enhanced_monitoring" {
  name               = "rds-enhanced-monitoring-aurora-lab02"
  assume_role_policy = data.aws_iam_policy_document.rds_monitoring_assume.json
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ---------------------------------------------------------------------------
# CloudWatch Alarms
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "aurora-lab02-alerts"
}

# CPU Writer > 80%
resource "aws_cloudwatch_metric_alarm" "writer_cpu" {
  alarm_name          = "aurora-writer-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Aurora Writer CPU > 80% durante 10 min"

  dimensions = {
    DBInstanceIdentifier = aws_rds_cluster_instance.writer.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# Replica Lag (si hay reader)
resource "aws_cloudwatch_metric_alarm" "replica_lag" {
  count = var.enable_reader ? 1 : 0

  alarm_name          = "aurora-replica-lag-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "AuroraReplicaLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 1000  # 1 segundo (Aurora debería ser <100ms)
  alarm_description   = "Aurora Replica Lag > 1s — shared storage issue"

  dimensions = {
    DBInstanceIdentifier = aws_rds_cluster_instance.reader[0].id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}
