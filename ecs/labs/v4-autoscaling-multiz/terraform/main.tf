# ── Lab v4: AutoScaling Multi-AZ + SQS Workers + Fargate Spot ────────────────
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = { Project = "shopapi", Lab = "v4-autoscaling", ManagedBy = "terraform" }
  }
}

data "aws_caller_identity" "current" {}

# ── Data sources — v2/v3 existentes ─────────────────────────────────────────
data "aws_vpc" "main"          { filter { name = "tag:Name"; values = ["${var.project_prefix}-vpc"] } }
data "aws_ecs_cluster" "main"  { cluster_name = "${var.project_prefix}-cluster" }
data "aws_lb" "main"           { name = "${var.project_prefix}-alb" }
data "aws_lb_target_group" "api" { name = "${var.project_prefix}-api-tg" }
data "aws_iam_role" "execution" { name = "${var.project_prefix}-execution-role" }
data "aws_iam_role" "task"      { name = "${var.project_prefix}-task-role" }

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  filter {
    name   = "tag:Tier"
    values = ["private"]
  }
}

# ── Tercera AZ (eu-west-1c) ───────────────────────────────────────────────────

resource "aws_subnet" "public_c" {
  vpc_id            = data.aws_vpc.main.id
  cidr_block        = var.subnet_cidr_public_c
  availability_zone = "${var.aws_region}c"
  tags              = { Name = "${var.project_prefix}-public-c", Tier = "public" }
}

resource "aws_subnet" "private_c" {
  vpc_id            = data.aws_vpc.main.id
  cidr_block        = var.subnet_cidr_private_c
  availability_zone = "${var.aws_region}c"
  tags              = { Name = "${var.project_prefix}-private-c", Tier = "private" }
}

# Asociar la subnet privada c a la route table privada existente
data "aws_route_table" "private" {
  filter {
    name   = "tag:Name"
    values = ["${var.project_prefix}-private-rt"]
  }
}

resource "aws_route_table_association" "private_c" {
  subnet_id      = aws_subnet.private_c.id
  route_table_id = data.aws_route_table.private.id
}

# ── SQS: cola de órdenes + DLQ ────────────────────────────────────────────────

resource "aws_sqs_queue" "orders_dlq" {
  name                       = "${var.project_prefix}-orders-dlq"
  message_retention_seconds  = 1209600 # 14 días
}

resource "aws_sqs_queue" "orders" {
  name                       = "${var.project_prefix}-orders"
  visibility_timeout_seconds = 300     # Tiempo que el worker tiene para procesar un mensaje
  message_retention_seconds  = 86400   # 1 día

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.orders_dlq.arn
    maxReceiveCount     = 3            # 3 intentos antes de mover al DLQ
  })
}

# Policy SQS para que ECS tasks puedan enviar y recibir mensajes
resource "aws_sqs_queue_policy" "orders" {
  queue_url = aws_sqs_queue.orders.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = data.aws_iam_role.task.arn }
      Action    = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
      Resource  = aws_sqs_queue.orders.arn
    }]
  })
}

# ── ECS Task Definition: worker ───────────────────────────────────────────────

resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.project_prefix}-worker"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = data.aws_iam_role.execution.arn
  task_role_arn            = data.aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "${var.project_prefix}-worker"
    image     = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.project_prefix}/api:${var.app_version}"
    essential = true

    environment = [
      { name = "APP_ENV",        value = "production" },
      { name = "WORKER_MODE",    value = "true" },
      { name = "SQS_ORDERS_URL", value = aws_sqs_queue.orders.url },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project_prefix}"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "${var.project_prefix}-worker"
      }
    }

    healthCheck = {
      command     = ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 20
    }

    stopTimeout = 120 # Dar tiempo al worker para terminar el mensaje actual
  }])
}

# SG para los workers (mismo que la API, reutilizamos)
data "aws_security_group" "tasks" {
  filter {
    name   = "tag:Name"
    values = ["${var.project_prefix}-tasks-sg"]
  }
}

# ── ECS Service: workers con Capacity Provider Strategy ───────────────────────

resource "aws_ecs_service" "worker" {
  name                   = "${var.project_prefix}-worker"
  cluster                = data.aws_ecs_cluster.main.arn
  task_definition        = aws_ecs_task_definition.worker.arn
  desired_count          = var.worker_desired_count
  enable_execute_command = true

  # Mezcla FARGATE (25%) + FARGATE_SPOT (75%) para reducir costes
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1      # Siempre 1 task garantizada en On-Demand
    weight            = 1
  }
  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    base              = 0
    weight            = 3      # 75% de las tasks adicionales en Spot
  }

  network_configuration {
    subnets          = concat(data.aws_subnets.private.ids, [aws_subnet.private_c.id])
    security_groups  = [data.aws_security_group.tasks.id]
    assign_public_ip = false
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [desired_count] # Auto Scaling gestiona el count
  }
}

# ── Auto Scaling: API (por ALB RequestCount) ──────────────────────────────────

resource "aws_appautoscaling_target" "api" {
  max_capacity       = var.api_max_tasks
  min_capacity       = var.api_min_tasks
  resource_id        = "service/${data.aws_ecs_cluster.main.cluster_name}/${var.project_prefix}-api"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "api_alb" {
  name               = "${var.project_prefix}-api-target-tracking"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  service_namespace  = aws_appautoscaling_target.api.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.api_alb_target_value # requests/task
    scale_in_cooldown  = 120
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${data.aws_lb.main.arn_suffix}/${data.aws_lb_target_group.api.arn_suffix}"
    }
  }
}

# Scheduled Scaling: Black Friday pre-warm
resource "aws_appautoscaling_scheduled_action" "black_friday" {
  name               = "${var.project_prefix}-black-friday-prewarm"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  # Último viernes de noviembre a las 20:00 UTC
  schedule           = "cron(0 20 ? 11 FRI#4 *)"

  scalable_target_action {
    min_capacity = var.api_black_friday_min
    max_capacity = var.api_max_tasks
  }
}

# ── Auto Scaling: Workers (por SQS depth) ─────────────────────────────────────

resource "aws_appautoscaling_target" "worker" {
  max_capacity       = var.worker_max_tasks
  min_capacity       = var.worker_min_tasks
  resource_id        = "service/${data.aws_ecs_cluster.main.cluster_name}/${var.project_prefix}-worker"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
  depends_on         = [aws_ecs_service.worker]
}

# Alarma: mensajes visibles en SQS → escala workers
resource "aws_cloudwatch_metric_alarm" "sqs_backlog" {
  alarm_name          = "${var.project_prefix}-sqs-backlog-high"
  alarm_description   = "Cola de órdenes con >50 mensajes por task — escalar workers"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = var.sqs_messages_per_task * var.worker_min_tasks
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  dimensions          = { QueueName = aws_sqs_queue.orders.name }

  alarm_actions = [aws_appautoscaling_policy.worker_sqs.arn]
}

resource "aws_appautoscaling_policy" "worker_sqs" {
  name               = "${var.project_prefix}-worker-sqs"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.worker.resource_id
  scalable_dimension = aws_appautoscaling_target.worker.scalable_dimension
  service_namespace  = aws_appautoscaling_target.worker.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Sum"

    step_adjustment {
      scaling_adjustment          = 2
      metric_interval_lower_bound = 0
    }
  }
}
