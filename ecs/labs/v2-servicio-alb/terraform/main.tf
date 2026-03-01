################################################################################
# Lab v2 ShopAPI — Terraform
# ECS Service con ALB, VPC personalizada y subnets públicas/privadas
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
      Project     = "ShopAPI"
      Lab         = "v2"
      ManagedBy   = "Terraform"
      Environment = "lab"
    }
  }
}

################################################################################
# Data Sources
################################################################################

# Obtener las AZs disponibles en la región dinámicamente
data "aws_availability_zones" "disponibles" {
  state = "available"
}

# Cuenta AWS actual
data "aws_caller_identity" "actual" {}

# Cluster ECS existente (creado en Lab v1)
data "aws_ecs_cluster" "shopapi" {
  cluster_name = var.cluster_name
}

# Imagen ECR más reciente
data "aws_ecr_repository" "shopapi_api" {
  name = var.ecr_repository_name
}

# Role de ejecución de ECS (creado en Lab v1)
data "aws_iam_role" "ecs_task_execution" {
  name = "ecsTaskExecutionRole"
}

################################################################################
# Locals
################################################################################

locals {
  # Usar las AZs configuradas o las primeras 2 disponibles
  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(
    data.aws_availability_zones.disponibles.names, 0, 2
  )

  account_id = data.aws_caller_identity.actual.account_id

  ecr_image_uri = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.ecr_repository_name}:latest"

  log_group_name = "/ecs/${var.task_family}"
}

################################################################################
# VPC
################################################################################

resource "aws_vpc" "shopapi" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "shopapi-vpc"
  }
}

################################################################################
# Subnets Públicas
################################################################################

resource "aws_subnet" "publica" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.shopapi.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "shopapi-public-${substr(local.azs[count.index], -1, 1)}"
    Type = "public"
  }
}

################################################################################
# Subnets Privadas
################################################################################

resource "aws_subnet" "privada" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.shopapi.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "shopapi-private-${substr(local.azs[count.index], -1, 1)}"
    Type = "private"
  }
}

################################################################################
# Internet Gateway
################################################################################

resource "aws_internet_gateway" "shopapi" {
  vpc_id = aws_vpc.shopapi.id

  tags = {
    Name = "shopapi-igw"
  }
}

################################################################################
# Elastic IP y NAT Gateway (en la primera subnet pública)
################################################################################

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "shopapi-nat-eip"
  }

  # Asegurar que el IGW existe antes que la EIP (dependencia implícita)
  depends_on = [aws_internet_gateway.shopapi]
}

resource "aws_nat_gateway" "shopapi" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.publica[0].id

  tags = {
    Name = "shopapi-nat"
  }

  depends_on = [aws_internet_gateway.shopapi]
}

################################################################################
# Route Tables
################################################################################

# Route table pública → IGW
resource "aws_route_table" "publica" {
  vpc_id = aws_vpc.shopapi.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.shopapi.id
  }

  tags = {
    Name = "shopapi-rt-public"
  }
}

# Asociar route table pública a todas las subnets públicas
resource "aws_route_table_association" "publica" {
  count = length(aws_subnet.publica)

  subnet_id      = aws_subnet.publica[count.index].id
  route_table_id = aws_route_table.publica.id
}

# Route table privada → NAT GW
resource "aws_route_table" "privada" {
  vpc_id = aws_vpc.shopapi.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.shopapi.id
  }

  tags = {
    Name = "shopapi-rt-private"
  }
}

# Asociar route table privada a todas las subnets privadas
resource "aws_route_table_association" "privada" {
  count = length(aws_subnet.privada)

  subnet_id      = aws_subnet.privada[count.index].id
  route_table_id = aws_route_table.privada.id
}

################################################################################
# Security Groups
################################################################################

# SG para el ALB — permite tráfico HTTP desde Internet
resource "aws_security_group" "alb" {
  name        = "shopapi-alb-sg"
  description = "ShopAPI ALB — permite trafico HTTP desde Internet"
  vpc_id      = aws_vpc.shopapi.id

  ingress {
    description = "HTTP desde Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Todo el trafico saliente"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "shopapi-alb-sg"
  }
}

# SG para las ECS Tasks — solo permite tráfico desde el ALB SG (encadenamiento)
resource "aws_security_group" "tasks" {
  name        = "shopapi-task-sg"
  description = "ShopAPI Tasks — solo trafico desde el ALB SG"
  vpc_id      = aws_vpc.shopapi.id

  ingress {
    description     = "Puerto 8080 solo desde el ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Todo el trafico saliente (ECR, CloudWatch, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "shopapi-task-sg"
  }
}

################################################################################
# Application Load Balancer
################################################################################

resource "aws_lb" "shopapi" {
  name               = "shopapi-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.publica[*].id

  enable_deletion_protection = false

  tags = {
    Name = "shopapi-alb"
  }
}

################################################################################
# Target Group
################################################################################

resource "aws_lb_target_group" "shopapi" {
  name        = "shopapi-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.shopapi.id
  target_type = "ip"  # Requerido para awsvpc (Fargate)

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    matcher             = "200"
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
  }

  deregistration_delay = 60  # Reducido para demos — defecto es 300s

  tags = {
    Name = "shopapi-tg"
  }

  # Importante: recrear el TG antes de eliminar el antiguo
  # para evitar downtime durante actualizaciones de Terraform
  lifecycle {
    create_before_destroy = true
  }
}

################################################################################
# Listener HTTP:80
################################################################################

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.shopapi.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.shopapi.arn
  }

  tags = {
    Name = "shopapi-listener-http"
  }
}

################################################################################
# CloudWatch Log Group
################################################################################

resource "aws_cloudwatch_log_group" "ecs" {
  name              = local.log_group_name
  retention_in_days = 7

  tags = {
    Name = local.log_group_name
  }
}

################################################################################
# ECS Task Definition
################################################################################

resource "aws_ecs_task_definition" "shopapi" {
  family                   = var.task_family
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = data.aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name  = var.container_name
      image = local.ecr_image_uri

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "APP_VERSION", value = var.app_version },
        { name = "PORT", value = tostring(var.container_port) },
        { name = "LOG_LEVEL", value = "info" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = local.log_group_name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${var.container_port}/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }

      essential = true
    }
  ])

  tags = {
    Name = var.task_family
  }
}

################################################################################
# ECS Service
################################################################################

resource "aws_ecs_service" "shopapi" {
  name            = "shopapi-api-service"
  cluster         = data.aws_ecs_cluster.shopapi.id
  task_definition = aws_ecs_task_definition.shopapi.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Red — subnets privadas con SG encadenado
  network_configuration {
    subnets          = aws_subnet.privada[*].id
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  # Integración con el ALB
  load_balancer {
    target_group_arn = aws_lb_target_group.shopapi.arn
    container_name   = var.container_name
    container_port   = var.container_port
  }

  # Tiempo de gracia para el health check del ALB
  health_check_grace_period_seconds = var.health_check_grace_period

  # Configuración del rolling update
  deployment_minimum_healthy_percent = var.minimum_healthy_percent
  deployment_maximum_percent         = var.maximum_percent

  # Circuit breaker — rollback automático si el deployment falla
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Propagar tags del servicio a las tasks
  propagate_tags = "SERVICE"

  # Asegurar que el listener existe antes del servicio
  depends_on = [
    aws_lb_listener.http,
    aws_cloudwatch_log_group.ecs,
  ]

  tags = {
    Name = "shopapi-api-service"
  }

  # Ignorar cambios en task_definition para permitir deploys externos (CLI, CI/CD)
  lifecycle {
    ignore_changes = [task_definition]
  }
}
