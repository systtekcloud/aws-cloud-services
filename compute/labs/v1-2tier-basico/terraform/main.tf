################################################################################
# Lab EC2 v1 — Terraform
# 2-tier básico: VPC + ALB + ASG con Launch Template (IMDSv2)
#
# Equivalente al CLI: cli/01-prereqs.sh + 02-networking.sh + 03-compute.sh
################################################################################

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
      Project     = var.project
      Lab         = "v1"
      ManagedBy   = "Terraform"
      Environment = var.environment
    }
  }
}

################################################################################
# Data Sources
################################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# AL2023 AMI más reciente (SSM Parameter)
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

################################################################################
# Locals
################################################################################

locals {
  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(
    data.aws_availability_zones.available.names, 0, 3
  )

  # NAT: uno por AZ o uno compartido según variable
  nat_gateway_count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : length(local.azs)) : 0

  ami_id     = data.aws_ssm_parameter.al2023_ami.value
  account_id = data.aws_caller_identity.current.account_id

  name_prefix = "${var.project}-${var.environment}"

  s3_bucket_name = var.s3_bucket_name != "" ? var.s3_bucket_name : "${local.name_prefix}-artefactos-${local.account_id}"
}

################################################################################
# VPC
################################################################################

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name_prefix}-igw" }
}

################################################################################
# Subnets
################################################################################

resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnets_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${local.name_prefix}-public-${local.azs[count.index]}" }
}

resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnets_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${local.name_prefix}-private-${local.azs[count.index]}" }
}

################################################################################
# NAT Gateways
################################################################################

resource "aws_eip" "nat" {
  count  = local.nat_gateway_count
  domain = "vpc"
  tags   = { Name = "${local.name_prefix}-nat-eip-${count.index + 1}" }
}

resource "aws_nat_gateway" "main" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = { Name = "${local.name_prefix}-nat-${count.index + 1}" }

  depends_on = [aws_internet_gateway.main]
}

################################################################################
# Route Tables
################################################################################

# Public: todo el tráfico sale por IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name_prefix}-rt-public" }
}

resource "aws_route_table_association" "public" {
  count = length(local.azs)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private: cada AZ sale por su NAT (o el único NAT si single_nat_gateway=true)
resource "aws_route_table" "private" {
  count  = length(local.azs)
  vpc_id = aws_vpc.main.id

  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.main[0].id : aws_nat_gateway.main[count.index].id
    }
  }

  tags = { Name = "${local.name_prefix}-rt-private-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "private" {
  count = length(local.azs)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

################################################################################
# S3 Gateway Endpoint (tráfico S3 sin salir a internet)
################################################################################

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = { Name = "${local.name_prefix}-ep-s3" }
}

################################################################################
# IAM — Rol para EC2
################################################################################

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_role" {
  name               = "${local.name_prefix}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.name_prefix}-ec2-role" }
}

# SSM (Session Manager — sin SSH abierto)
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# CloudWatch Agent
resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# S3 — acceso al bucket de artefactos
data "aws_iam_policy_document" "s3_artefactos" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["arn:aws:s3:::${local.s3_bucket_name}/*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.s3_bucket_name}"]
  }
}

resource "aws_iam_role_policy" "s3_artefactos" {
  name   = "s3-artefactos"
  role   = aws_iam_role.ec2_role.id
  policy = data.aws_iam_policy_document.s3_artefactos.json
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

################################################################################
# Security Groups
################################################################################

# ALB — internet-facing: solo 80/443 desde cualquier origen
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-sg-alb"
  description = "ALB externo — HTTP/HTTPS desde internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-sg-alb" }
}

# EC2 — solo acepta tráfico desde el SG del ALB
resource "aws_security_group" "ec2" {
  name        = "${local.name_prefix}-sg-ec2"
  description = "EC2 app — acepta solo desde ALB SG"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "App port desde ALB"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-sg-ec2" }
}

################################################################################
# S3 Bucket (artefactos)
################################################################################

resource "aws_s3_bucket" "artefactos" {
  bucket        = local.s3_bucket_name
  force_destroy = true # seguro en labs

  tags = { Name = "${local.name_prefix}-artefactos" }
}

resource "aws_s3_bucket_versioning" "artefactos" {
  bucket = aws_s3_bucket.artefactos.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artefactos" {
  bucket = aws_s3_bucket.artefactos.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "artefactos" {
  bucket                  = aws_s3_bucket.artefactos.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

################################################################################
# Launch Template
################################################################################

resource "aws_launch_template" "app" {
  name_prefix   = "${local.name_prefix}-lt-"
  image_id      = local.ami_id
  instance_type = var.instance_type

  key_name = var.key_name != "" ? var.key_name : null

  iam_instance_profile { arn = aws_iam_instance_profile.ec2.arn }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.ec2.id]
    delete_on_termination       = true
  }

  # IMDSv2 obligatorio
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = "gp3"
      volume_size           = 20
      delete_on_termination = true
      encrypted             = true
    }
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail

    # Instalar dependencias
    dnf install -y python3-pip python3 amazon-cloudwatch-agent
    pip3 install flask boto3 pymysql requests

    # Copiar app desde S3
    mkdir -p /opt/app
    aws s3 cp s3://${local.s3_bucket_name}/app/app.py /opt/app/app.py 2>/dev/null || \
      echo "INFO: app.py no encontrado en S3, arrancando app de demo"

    # App de demo si no hay app.py en S3
    if [ ! -f /opt/app/app.py ]; then
      cat > /opt/app/app.py << 'PYEOF'
    from flask import Flask, jsonify
    import subprocess, socket

    app = Flask(__name__)

    def imdsv2_get(path):
        token = subprocess.getoutput(
            'curl -sf -X PUT http://169.254.169.254/latest/api/token '
            '-H "X-aws-ec2-metadata-token-ttl-seconds: 21600"'
        )
        return subprocess.getoutput(
            f'curl -sf -H "X-aws-ec2-metadata-token: {token}" '
            f'http://169.254.169.254/latest/meta-data/{path}'
        )

    @app.route('/health')
    def health():
        return jsonify(status='healthy'), 200

    @app.route('/')
    def index():
        return jsonify(
            instance_id=imdsv2_get('instance-id'),
            az=imdsv2_get('placement/availability-zone'),
            hostname=socket.gethostname(),
            version='v1-demo'
        )

    if __name__ == '__main__':
        app.run(host='0.0.0.0', port=8080)
    PYEOF
    fi

    # Servicio systemd
    cat > /etc/systemd/system/app.service << 'SVC'
    [Unit]
    Description=EC2 Lab App
    After=network.target

    [Service]
    ExecStart=/usr/bin/python3 /opt/app/app.py
    Restart=always
    User=nobody
    WorkingDirectory=/opt/app

    [Install]
    WantedBy=multi-user.target
    SVC

    systemctl daemon-reload
    systemctl enable app
    systemctl start app
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${local.name_prefix}-app"
      Project = var.project
      Lab     = "v1"
    }
  }

  lifecycle { create_before_destroy = true }
}

################################################################################
# ALB + Target Group + Listener
################################################################################

resource "aws_lb_target_group" "app" {
  name        = "${local.name_prefix}-tg"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${local.name_prefix}-tg" }
}

resource "aws_lb" "app" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false # false en labs

  tags = { Name = "${local.name_prefix}-alb" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

################################################################################
# Auto Scaling Group
################################################################################

resource "aws_autoscaling_group" "app" {
  name = "${local.name_prefix}-asg"

  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

  # Instancias en subnets privadas
  vpc_zone_identifier = aws_subnet.private[*].id

  # Health check: ELB tiene prioridad sobre EC2 para detectar fallos de app
  health_check_type         = "ELB"
  health_check_grace_period = 120

  target_group_arns = [aws_lb_target_group.app.arn]

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  # Instance refresh: actualizaciones sin downtime
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-app"
    propagate_at_launch = true
  }

  lifecycle { create_before_destroy = true }
}

# Target Tracking — CPU al 60%: crea CW Alarms automáticamente
resource "aws_autoscaling_policy" "cpu_tracking" {
  name                   = "${local.name_prefix}-cpu-tracking"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.asg_cpu_target
  }
}
