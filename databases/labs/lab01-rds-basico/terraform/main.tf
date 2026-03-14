# =============================================================================
# Lab 01 — RDS MySQL: Infraestructura completa en Terraform
#
# Recursos que crea este módulo:
#   - VPC (10.20.0.0/16) con DNS habilitado
#   - 5 subnets (2 públicas, 2 privadas DB, 1 privada app)
#   - Internet Gateway + NAT Gateway + Elastic IP
#   - Route Tables (pública → IGW, privada → NAT)
#   - 3 Security Groups (sg-app, sg-rds, sg-ssm-ep)
#   - 3 VPC Interface Endpoints SSM
#   - IAM Role + Instance Profile para SSM
#   - EC2 t3.micro (Amazon Linux 2023, sin keypair)
#   - KMS CMK con rotación anual
#   - DB Subnet Group
#   - Secrets Manager secret + rotación
#   - RDS MySQL 8.0 (Single-AZ o Multi-AZ según variable)
#   - Read Replica (opcional: var.enable_read_replica)
#   - CloudWatch Alarms
#
# Uso:
#   terraform init
#   terraform plan
#   terraform apply
#   terraform destroy   # cleanup
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

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

# =============================================================================
# PROVIDER
# =============================================================================

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      Lab       = var.lab
      ManagedBy = "terraform"
      Env       = var.env
    }
  }
}

# =============================================================================
# DATA SOURCES
# =============================================================================

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# AMI Amazon Linux 2023 más reciente
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# =============================================================================
# VPC
# =============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "vpc-${var.project}" }
}

# =============================================================================
# SUBNETS
# =============================================================================

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_public_a_cidr
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
  tags                    = { Name = "public-a" }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_public_b_cidr
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = true
  tags                    = { Name = "public-b" }
}

resource "aws_subnet" "private_db_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_db_a_cidr
  availability_zone = "${var.aws_region}a"
  tags              = { Name = "private-db-a" }
}

resource "aws_subnet" "private_db_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_db_b_cidr
  availability_zone = "${var.aws_region}b"
  tags              = { Name = "private-db-b" }
}

resource "aws_subnet" "private_app_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_app_a_cidr
  availability_zone = "${var.aws_region}a"
  tags              = { Name = "private-app-a" }
}

# =============================================================================
# INTERNET GATEWAY + NAT GATEWAY
# =============================================================================

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "igw-${var.project}" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "eip-nat-${var.project}" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id
  tags          = { Name = "nat-${var.project}" }
  depends_on    = [aws_internet_gateway.main]
}

# =============================================================================
# ROUTE TABLES
# =============================================================================

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "rt-public-${var.project}" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "rt-private-${var.project}" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_db_a" {
  subnet_id      = aws_subnet.private_db_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_db_b" {
  subnet_id      = aws_subnet.private_db_b.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_app_a" {
  subnet_id      = aws_subnet.private_app_a.id
  route_table_id = aws_route_table.private.id
}

# =============================================================================
# SECURITY GROUPS
# =============================================================================

resource "aws_security_group" "app" {
  name        = "sg-app-${var.project}"
  description = "SG para instancia de aplicacion"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sg-app-${var.project}" }
}

resource "aws_security_group" "rds" {
  name        = "sg-rds-${var.project}"
  description = "SG para RDS MySQL - solo desde sg-app"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
    description     = "MySQL desde sg-app"
  }

  tags = { Name = "sg-rds-${var.project}" }
}

resource "aws_security_group" "ssm_endpoints" {
  name        = "sg-ssm-ep-${var.project}"
  description = "SG para VPC endpoints SSM"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "HTTPS desde VPC para SSM"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sg-ssm-ep-${var.project}" }
}

# =============================================================================
# VPC ENDPOINTS SSM (sin estos, Session Manager no funciona en subnet privada)
# =============================================================================

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_app_a.id]
  security_group_ids  = [aws_security_group.ssm_endpoints.id]
  private_dns_enabled = true
  tags                = { Name = "ep-ssm-${var.project}" }
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_app_a.id]
  security_group_ids  = [aws_security_group.ssm_endpoints.id]
  private_dns_enabled = true
  tags                = { Name = "ep-ssmmessages-${var.project}" }
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_app_a.id]
  security_group_ids  = [aws_security_group.ssm_endpoints.id]
  private_dns_enabled = true
  tags                = { Name = "ep-ec2messages-${var.project}" }
}

# =============================================================================
# IAM ROLE + INSTANCE PROFILE PARA SSM
# =============================================================================

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_ssm" {
  name               = "role-ec2-ssm-${var.project}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "secrets_ro" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
}

resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "role-ec2-ssm-${var.project}"
  role = aws_iam_role.ec2_ssm.name
}

# =============================================================================
# EC2 INSTANCIA DE APLICACIÓN
# =============================================================================

resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private_app_a.id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name

  tags = { Name = "db-lab-rds-app" }
}

# =============================================================================
# KMS CMK
# =============================================================================

resource "aws_kms_key" "rds" {
  description             = "CMK para RDS MySQL ${var.project}"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  tags = { Name = "kms-rds-${var.project}" }
}

resource "aws_kms_alias" "rds" {
  name          = "alias/db-lab-rds-key"
  target_key_id = aws_kms_key.rds.key_id
}

# =============================================================================
# DB SUBNET GROUP
# =============================================================================

resource "aws_db_subnet_group" "main" {
  name        = "db-lab-rds-subnetgroup"
  description = "Subnets privadas para RDS ${var.project}"
  subnet_ids  = [aws_subnet.private_db_a.id, aws_subnet.private_db_b.id]

  tags = { Name = "db-lab-rds-subnetgroup" }
}

# =============================================================================
# SECRETS MANAGER
# =============================================================================

resource "random_password" "db" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "rds_credentials" {
  name        = "db-lab-rds-credentials"
  description = "Credenciales admin para RDS MySQL ${var.project}"
  kms_key_id  = aws_kms_key.rds.arn

  tags = { Name = "db-lab-rds-credentials" }
}

resource "aws_secretsmanager_secret_version" "rds_credentials" {
  secret_id = aws_secretsmanager_secret.rds_credentials.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.db.result
    engine   = "mysql"
    port     = 3306
    dbname   = var.rds_db_name
  })
}

# =============================================================================
# RDS MySQL 8.0
# =============================================================================

resource "aws_db_instance" "main" {
  identifier        = "db-lab-rds-instance"
  engine            = "mysql"
  engine_version    = var.rds_engine_version
  instance_class    = var.rds_instance_class
  allocated_storage = var.rds_storage_gb
  storage_type      = "gp2"
  db_name           = var.rds_db_name

  username = "admin"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  availability_zone      = "${var.aws_region}a"
  publicly_accessible    = false
  multi_az               = var.enable_multi_az

  storage_encrypted = true
  kms_key_id        = aws_kms_key.rds.arn

  backup_retention_period   = var.backup_retention_period
  backup_window             = "02:00-03:00"
  maintenance_window        = "Mon:03:00-Mon:04:00"
  auto_minor_version_upgrade = true

  enabled_cloudwatch_logs_exports = ["error", "slowquery"]
  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.rds_enhanced_monitoring.arn

  skip_final_snapshot = true # Solo para lab

  tags = { Name = "db-lab-rds-instance" }
}

# IAM Role para Enhanced Monitoring
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
  name               = "role-rds-monitoring-${var.project}"
  assume_role_policy = data.aws_iam_policy_document.rds_monitoring_assume.json
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# =============================================================================
# READ REPLICA (opcional)
# =============================================================================

resource "aws_db_instance" "replica" {
  count = var.enable_read_replica ? 1 : 0

  identifier             = "db-lab-rds-replica"
  replicate_source_db    = aws_db_instance.main.identifier
  instance_class         = var.rds_instance_class
  availability_zone      = "${var.aws_region}b"
  publicly_accessible    = false
  vpc_security_group_ids = [aws_security_group.rds.id]
  auto_minor_version_upgrade = true
  skip_final_snapshot    = true

  tags = { Name = "db-lab-rds-replica" }
}

# =============================================================================
# CLOUDWATCH ALARMS
# =============================================================================

resource "aws_sns_topic" "rds_alerts" {
  name = "db-labs-rds-alerts"
}

resource "aws_cloudwatch_metric_alarm" "storage_low" {
  alarm_name          = "db-lab-rds-storage-low"
  alarm_description   = "RDS: espacio en disco < 2GB"
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2147483648
  comparison_operator = "LessThanThreshold"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.identifier
  }

  alarm_actions = [aws_sns_topic.rds_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "db-lab-rds-cpu-high"
  alarm_description   = "RDS: CPU > 80%"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.identifier
  }

  alarm_actions = [aws_sns_topic.rds_alerts.arn]
}
