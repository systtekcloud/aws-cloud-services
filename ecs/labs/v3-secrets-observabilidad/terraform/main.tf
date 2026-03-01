# ── Lab v3: Secrets Manager + IAM + CloudWatch Alarms ────────────────────────
# Este Terraform añade las capas de seguridad y observabilidad sobre v2.
# Prerrequisito: v2 aplicado (cluster, service, ALB, VPC ya existen).

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
      Lab       = "v3-secrets-observabilidad"
      ManagedBy = "terraform"
    }
  }
}

# ── Data sources — recursos creados en v2 ─────────────────────────────────────
data "aws_ecs_cluster" "main" {
  cluster_name = "${var.project_prefix}-cluster"
}

data "aws_lb" "main" {
  name = "${var.project_prefix}-alb"
}

data "aws_lb_target_group" "api" {
  name = "${var.project_prefix}-api-tg"
}

data "aws_iam_role" "execution" {
  name = "${var.project_prefix}-execution-role"
}

# ── Secrets Manager ───────────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "db" {
  name        = "${var.project_prefix}/prod/db"
  description = "Credenciales de base de datos para ShopAPI (simuladas en lab)"

  # En producción: rotation_rules para rotación automática
  # rotation_lambda_arn = aws_lambda_function.rotation.arn

  tags = {
    Component = "database"
    Env       = "prod"
  }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  # Valor JSON con las credenciales simuladas
  secret_string = jsonencode({
    host     = "db.shopapi.internal"
    port     = 5432
    username = "shopapi_app"
    password = "changeme_en_produccion"
    dbname   = "shopapi"
  })
}

# ── IAM: Task Role (permisos de la aplicación) ────────────────────────────────

data "aws_iam_policy_document" "task_trust" {
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

resource "aws_iam_role" "task" {
  name               = "${var.project_prefix}-task-role"
  description        = "Task Role — permisos para la aplicación ShopAPI en runtime"
  assume_role_policy = data.aws_iam_policy_document.task_trust.json
}

# Policy: acceso a DynamoDB (para versiones futuras con USE_DYNAMODB=true)
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
      "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/shopapi-*"
    ]
  }
}

resource "aws_iam_role_policy" "task_dynamo" {
  name   = "DynamoDBAccess"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_dynamo.json
}

data "aws_caller_identity" "current" {}

# ── IAM: Actualizar Execution Role con permisos Secrets Manager ───────────────

data "aws_iam_policy_document" "execution_secrets" {
  statement {
    sid    = "AllowGetShopApiSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    # ARN con wildcard para el sufijo aleatorio de Secrets Manager (-xxxxxx)
    resources = ["${aws_secretsmanager_secret.db.arn}*"]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "SecretsManagerAccess"
  role   = data.aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

# ── Container Insights ────────────────────────────────────────────────────────

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = data.aws_ecs_cluster.main.cluster_name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 1
    capacity_provider = "FARGATE"
  }
}

# Habilitar Container Insights (no es un recurso Terraform directo, se hace via aws_ecs_cluster)
# Si el cluster ya existe, usar aws_ecs_cluster con lifecycle ignore_changes
# En un nuevo cluster:
# resource "aws_ecs_cluster" "main" {
#   setting { name = "containerInsights" value = "enabled" }
# }

# ── CloudWatch Log Group (con retención) ──────────────────────────────────────

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project_prefix}"
  retention_in_days = var.log_retention_days

  tags = {
    Component = "logging"
  }
}

# ── SNS Topic para alarmas ────────────────────────────────────────────────────

resource "aws_sns_topic" "alerts" {
  name = "${var.project_prefix}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── CloudWatch Alarms ─────────────────────────────────────────────────────────

# Alarm 1: Tasa de errores 5xx en el ALB
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project_prefix}-alb-5xx-rate"
  alarm_description   = "Tasa de errores HTTP 5xx supera el 5% durante 2 minutos"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 5

  # Métrica: porcentaje de errores 5xx
  metric_query {
    id          = "error_rate"
    expression  = "errors / total * 100"
    label       = "5xx Rate %"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = data.aws_lb.main.arn_suffix
      }
    }
  }

  metric_query {
    id = "total"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = data.aws_lb.main.arn_suffix
      }
    }
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
  treat_missing_data = "notBreaching"
}

# Alarm 2: Latencia P99 alta
resource "aws_cloudwatch_metric_alarm" "alb_latency_p99" {
  alarm_name          = "${var.project_prefix}-alb-latency-p99"
  alarm_description   = "Latencia P99 del ALB supera 1 segundo"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = 1.0 # segundos
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  extended_statistic  = "p99"

  dimensions = {
    LoadBalancer = data.aws_lb.main.arn_suffix
  }

  alarm_actions      = [aws_sns_topic.alerts.arn]
  treat_missing_data = "notBreaching"
}

# Alarm 3: Número de tasks corriendo menor que el deseado
resource "aws_cloudwatch_metric_alarm" "ecs_tasks_low" {
  alarm_name          = "${var.project_prefix}-ecs-tasks-below-desired"
  alarm_description   = "Número de tasks corriendo por debajo del count deseado"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  threshold           = var.desired_count
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Average"

  dimensions = {
    ClusterName = data.aws_ecs_cluster.main.cluster_name
    ServiceName = "${var.project_prefix}-api"
  }

  alarm_actions      = [aws_sns_topic.alerts.arn]
  treat_missing_data = "breaching" # Si no hay datos, asumir problema
}

# ── Task Definition actualizada (con secrets + task role) ─────────────────────

resource "aws_ecs_task_definition" "api_v3" {
  family                   = "${var.project_prefix}-api"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = data.aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn # Añadido en v3

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

      # Variables de entorno no sensibles
      environment = [
        { name = "APP_ENV",     value = "production" },
        { name = "APP_VERSION", value = var.app_version },
      ]

      # Secrets inyectados desde Secrets Manager (nunca en environment)
      secrets = [
        {
          name      = "DB_HOST"
          valueFrom = "${aws_secretsmanager_secret.db.arn}:host::"
        },
        {
          name      = "DB_PASSWORD"
          valueFrom = "${aws_secretsmanager_secret.db.arn}:password::"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
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
