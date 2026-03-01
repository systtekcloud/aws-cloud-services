# ── Lab v6: Cost Optimization — VPC Endpoints + ARM64 + FARGATE_SPOT ─────────
# Añade optimizaciones de coste sobre v4/v5:
#   - VPC Endpoints privados (evita NAT Gateway para tráfico AWS)
#   - Task Definition con runtimePlatform ARM64 (Graviton, ~20% ahorro)
#   - Estrategia Capacity Provider con FARGATE_SPOT para workers
# Prerrequisito: v4 aplicado (cluster, servicios, ALB, VPC, SQS existen).

terraform {
  required_version = ">= 1.6"
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
      Project   = "shopapi"
      Lab       = "v6-cost-optimization"
      ManagedBy = "terraform"
    }
  }
}

# ── Data sources — recursos creados en v1-v5 ──────────────────────────────────

data "aws_caller_identity" "current" {}

data "aws_vpc" "main" {
  tags = {
    Name = "${var.project_prefix}-vpc"
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = {
    Tier = "private"
  }
}

data "aws_route_table" "private" {
  vpc_id = data.aws_vpc.main.id
  filter {
    name   = "tag:Name"
    values = ["${var.project_prefix}-private-rt"]
  }
}

data "aws_ecs_cluster" "main" {
  cluster_name = "${var.project_prefix}-cluster"
}

data "aws_iam_role" "execution" {
  name = "${var.project_prefix}-execution-role"
}

data "aws_iam_role" "task" {
  name = "${var.project_prefix}-task-role"
}

data "aws_sqs_queue" "orders" {
  name = "${var.project_prefix}-orders"
}

data "aws_lb" "main" {
  name = "${var.project_prefix}-alb"
}

data "aws_lb_target_group" "api" {
  name = "${var.project_prefix}-api-tg"
}

data "aws_security_group" "ecs_tasks" {
  name   = "${var.project_prefix}-ecs-tasks-sg"
  vpc_id = data.aws_vpc.main.id
}

# ── Security Group para VPC Endpoints ────────────────────────────────────────

resource "aws_security_group" "vpce" {
  count       = var.enable_vpc_endpoints ? 1 : 0
  name        = "${var.project_prefix}-vpce-sg"
  description = "Permite trafico HTTPS desde tasks ECS a los VPC Endpoints"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description     = "HTTPS desde tasks ECS"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [data.aws_security_group.ecs_tasks.id]
  }

  egress {
    description = "Todo el trafico de salida"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_prefix}-vpce-sg"
  }
}

# ── VPC Endpoints Interface (ECR API, ECR DKR, CloudWatch Logs, Secrets Manager)

locals {
  interface_endpoints = var.enable_vpc_endpoints ? {
    "ecr-api"        = "com.amazonaws.${var.aws_region}.ecr.api"
    "ecr-dkr"        = "com.amazonaws.${var.aws_region}.ecr.dkr"
    "logs"           = "com.amazonaws.${var.aws_region}.logs"
    "secretsmanager" = "com.amazonaws.${var.aws_region}.secretsmanager"
  } : {}
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = data.aws_vpc.main.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.aws_subnets.private.ids
  security_group_ids  = [aws_security_group.vpce[0].id]
  private_dns_enabled = true

  tags = {
    Name = "${var.project_prefix}-vpce-${each.key}"
  }
}

# ── VPC Endpoint Gateway (S3 — gratuito, necesario para capas ECR) ────────────

resource "aws_vpc_endpoint" "s3" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id            = data.aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [data.aws_route_table.private.id]

  tags = {
    Name = "${var.project_prefix}-vpce-s3"
  }
}

# ── Task Definition ARM64 (Graviton) — API ────────────────────────────────────

data "aws_secretsmanager_secret" "db" {
  name = "${var.project_prefix}/prod/db"
}

data "aws_cloudwatch_log_group" "ecs" {
  name = "/ecs/${var.project_prefix}"
}

resource "aws_ecs_task_definition" "api_arm64" {
  family                   = "${var.project_prefix}-api"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = data.aws_iam_role.execution.arn
  task_role_arn            = data.aws_iam_role.task.arn

  # Graviton ARM64
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      name      = "${var.project_prefix}-api"
      image     = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.project_prefix}/api:${var.app_version}"
      essential = true

      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "APP_ENV",     value = "production" },
        { name = "APP_VERSION", value = var.app_version },
      ]

      secrets = [
        {
          name      = "DB_HOST"
          valueFrom = "${data.aws_secretsmanager_secret.db.arn}:host::"
        },
        {
          name      = "DB_PASSWORD"
          valueFrom = "${data.aws_secretsmanager_secret.db.arn}:password::"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = data.aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = var.project_prefix
        }
      }

      healthCheck = {
        command     = ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
    }
  ])
}

# ── Task Definition ARM64 — Worker ────────────────────────────────────────────

resource "aws_ecs_task_definition" "worker_arm64" {
  family                   = "${var.project_prefix}-worker"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = data.aws_iam_role.execution.arn
  task_role_arn            = data.aws_iam_role.task.arn

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      name      = "${var.project_prefix}-worker"
      image     = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.project_prefix}/api:${var.app_version}"
      essential = true

      environment = [
        { name = "APP_ENV",        value = "production" },
        { name = "APP_VERSION",    value = var.app_version },
        { name = "WORKER_MODE",    value = "true" },
        { name = "SQS_ORDERS_URL", value = data.aws_sqs_queue.orders.url },
      ]

      stopTimeout = 120

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = data.aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "${var.project_prefix}-worker"
        }
      }
    }
  ])
}

# ── Actualizar servicio API con Capacity Provider SPOT + ARM64 ────────────────

resource "aws_ecs_service" "api" {
  name            = "${var.project_prefix}-api"
  cluster         = data.aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api_arm64.arn
  desired_count   = var.api_desired_count

  # API en FARGATE puro (latencia sensible, no interrupciones)
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = var.api_desired_count
    weight            = 1
  }

  network_configuration {
    subnets          = data.aws_subnets.private.ids
    security_groups  = [data.aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = data.aws_lb_target_group.api.arn
    container_name   = "${var.project_prefix}-api"
    container_port   = 8080
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100
  health_check_grace_period_seconds  = 60

  lifecycle {
    ignore_changes = [desired_count]
  }
}

# ── Actualizar servicio Worker con FARGATE_SPOT + ARM64 ───────────────────────

data "aws_ecs_service" "worker" {
  cluster_arn  = data.aws_ecs_cluster.main.arn
  service_name = "${var.project_prefix}-worker"
}

resource "aws_ecs_service" "worker" {
  name            = "${var.project_prefix}-worker"
  cluster         = data.aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker_arm64.arn
  desired_count   = var.worker_desired_count

  # Worker: mezcla FARGATE (garantía) + FARGATE_SPOT (ahorro)
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    weight            = 1
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    base              = 0
    weight            = 4
  }

  network_configuration {
    subnets          = data.aws_subnets.private.ids
    security_groups  = [data.aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  lifecycle {
    ignore_changes = [desired_count]
  }
}
