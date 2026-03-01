# ── Módulo: ECS Service — ShopAPI ─────────────────────────────────────────────
# Crea todos los recursos necesarios para ejecutar la aplicación en ECS Fargate:
#   - IAM Roles: Execution Role + Task Role
#   - CloudWatch Log Group
#   - Security Group para las tasks
#   - Task Definition (ARM64 Graviton)
#   - ECS Service con Capacity Provider strategy
#   - Alarmas CloudWatch (si se proporciona ops_email)

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ── CloudWatch Log Group ──────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/shopapi-${var.environment}"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "shopapi-logs-${var.environment}"
  }
}

# ── IAM: Execution Role ───────────────────────────────────────────────────────
# Usado por el agente de ECS para hacer pull de la imagen y desencriptar secretos.
# Distinto del Task Role: este es para el plano de control, no para la app.

data "aws_iam_policy_document" "ecs_trust" {
  statement {
    sid     = "AllowECSTasksToAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "shopapi-execution-role-${var.environment}"
  description        = "Execution Role de ECS — pull de imagen ECR e inyección de secretos"
  assume_role_policy = data.aws_iam_policy_document.ecs_trust.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ── IAM: Task Role ────────────────────────────────────────────────────────────
# Permisos de la aplicación en runtime: DynamoDB, SQS, etc.
# La app asume este role para llamar a la API de AWS.

resource "aws_iam_role" "task" {
  name               = "shopapi-task-role-${var.environment}"
  description        = "Task Role de ShopAPI — permisos de la aplicación en runtime"
  assume_role_policy = data.aws_iam_policy_document.ecs_trust.json
}

data "aws_iam_policy_document" "task_dynamo" {
  statement {
    sid    = "AllowDynamoDBReadWrite"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Scan",
      "dynamodb:Query",
    ]
    resources = [
      "arn:aws:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/shopapi-*"
    ]
  }
}

resource "aws_iam_role_policy" "task_dynamo" {
  name   = "DynamoDBAccess"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_dynamo.json
}

# ── Security Group de las tasks ───────────────────────────────────────────────
# Solo acepta tráfico desde el Security Group del ALB — no desde internet.

resource "aws_security_group" "ecs_tasks" {
  name        = "shopapi-ecs-tasks-sg-${var.environment}"
  description = "Permite tráfico desde el ALB al puerto de la aplicación"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Tráfico desde el ALB al puerto de la app"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [var.alb_security_group_id]
  }

  egress {
    description = "Todo el tráfico de salida (AWS APIs, ECR, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "shopapi-ecs-tasks-sg-${var.environment}"
  }
}

# ── Task Definition (ARM64 Graviton) ──────────────────────────────────────────
# ARM64 es ~20% más barato que X86_64 en Fargate.
# La imagen debe haberse compilado para linux/arm64.

resource "aws_ecs_task_definition" "api" {
  family                   = "shopapi-api-${var.environment}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      name      = var.service_name
      image     = var.container_image
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "APP_ENV",     value = var.environment },
        { name = "APP_VERSION", value = "latest" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "shopapi"
        }
      }

      healthCheck = {
        command     = ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:${var.container_port}/health')"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
    }
  ])

  tags = {
    Name = "shopapi-api-td-${var.environment}"
  }
}

# ── ECS Service ───────────────────────────────────────────────────────────────

resource "aws_ecs_service" "api" {
  name            = var.service_name
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.desired_count

  dynamic "capacity_provider_strategy" {
    for_each = var.capacity_provider_strategy
    content {
      capacity_provider = capacity_provider_strategy.value.capacity_provider
      weight            = capacity_provider_strategy.value.weight
      base              = capacity_provider_strategy.value.base
    }
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = var.service_name
    container_port   = var.container_port
  }

  deployment_circuit_breaker {
    enable   = var.deployment_circuit_breaker_enabled
    rollback = var.deployment_circuit_breaker_rollback
  }

  deployment_maximum_percent         = var.deployment_maximum_percent
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  health_check_grace_period_seconds  = 60

  # ignore_changes en desired_count: el Auto Scaling gestiona el conteo en runtime.
  # ignore_changes en task_definition: CI/CD actualiza la imagen sin pasar por Terraform.
  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  tags = {
    Name = "shopapi-api-svc-${var.environment}"
  }
}

# ── SNS Topic y suscripción de email para alarmas (solo si se configura ops_email) ──

resource "aws_sns_topic" "alerts" {
  count = var.ops_email != "" ? 1 : 0
  name  = "shopapi-alerts-${var.environment}"

  tags = {
    Name = "shopapi-alerts-${var.environment}"
  }
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.ops_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.ops_email
}

# ── CloudWatch Alarm: tasa de errores 5xx ────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  count = var.ops_email != "" ? 1 : 0

  alarm_name          = "shopapi-alb-5xx-${var.environment}"
  alarm_description   = "Tasa de errores 5xx supera el ${var.alarm_5xx_threshold}%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.alarm_5xx_threshold
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate"
    expression  = "errors / total * 100"
    label       = "5xx Error Rate %"
    return_data = true
  }
  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 60
      stat        = "Sum"
    }
  }
  metric_query {
    id = "total"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 60
      stat        = "Sum"
    }
  }

  alarm_actions = [aws_sns_topic.alerts[0].arn]
  ok_actions    = [aws_sns_topic.alerts[0].arn]
}

# ── CloudWatch Alarm: latencia P99 ────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "alb_latency_p99" {
  count = var.ops_email != "" ? 1 : 0

  alarm_name          = "shopapi-alb-latency-p99-${var.environment}"
  alarm_description   = "Latencia P99 del ALB supera ${var.alarm_latency_p99_seconds}s"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = var.alarm_latency_p99_seconds
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  extended_statistic  = "p99"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts[0].arn]
}
