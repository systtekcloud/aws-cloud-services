# =============================================================================
# Lab v1 — ShopAPI en ECS Fargate
# Terraform: Infraestructura completa del lab
#
# Recursos que crea este modulo:
#   - ECR Repository con lifecycle policy
#   - ECS Cluster con Container Insights
#   - CloudWatch Log Group
#   - IAM Role de ejecucion para ECS
#   - ECS Task Definition (Fargate)
#   - null_resource para docker build+push
#
# Uso:
#   terraform init
#   terraform plan -var="account_id=123456789012"
#   terraform apply -var="account_id=123456789012"
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

# =============================================================================
# PROVIDER
# =============================================================================

provider "aws" {
  region = var.aws_region

  # Etiquetas por defecto aplicadas a todos los recursos que soporten tags
  default_tags {
    tags = {
      Project     = var.project_prefix
      Lab         = "v1"
      ManagedBy   = "terraform"
      Environment = "lab"
    }
  }
}

# =============================================================================
# DATA SOURCES
# =============================================================================

# Datos de la cuenta activa (util para construir ARNs)
data "aws_caller_identity" "current" {}

# =============================================================================
# ECR REPOSITORY
# =============================================================================

# Repositorio privado de Docker en AWS
# Almacena las imagenes de contenedor de ShopAPI
resource "aws_ecr_repository" "shopapi_api" {
  name                 = "${var.project_prefix}/api"
  image_tag_mutability = "MUTABLE" # Permite sobreescribir el tag 'latest'

  # Escaneo automatico de vulnerabilidades en cada push
  image_scanning_configuration {
    scan_on_push = true
  }

  # Encriptacion de imagenes con clave KMS gestionada por AWS
  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Lifecycle policy: mantener solo las ultimas N imagenes etiquetadas
# Esto evita que el repositorio crezca indefinidamente y genera costes innecesarios
resource "aws_ecr_lifecycle_policy" "shopapi_api" {
  repository = aws_ecr_repository.shopapi_api.name

  policy = jsonencode({
    rules = [
      {
        # Regla 1: Eliminar imagenes sin etiqueta mas antiguas de 1 dia
        rulePriority = 1
        description  = "Eliminar imagenes sin tag antiguas"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = {
          type = "expire"
        }
      },
      {
        # Regla 2: Mantener solo las ultimas 5 imagenes con tag
        rulePriority = 2
        description  = "Mantener solo las ultimas 5 imagenes etiquetadas"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "0.", "1.", "2.", "latest"]
          countType     = "imageCountMoreThan"
          countNumber   = var.ecr_max_images
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# =============================================================================
# ECS CLUSTER
# =============================================================================

# Cluster logico de ECS
# En Fargate, el cluster es solo un agrupador logico — no hay instancias EC2
resource "aws_ecs_cluster" "shopapi" {
  name = "${var.project_prefix}-cluster"

  # Container Insights: metricas detalladas de CPU, memoria, red y almacenamiento
  # por task y container en CloudWatch Metrics. Tiene coste adicional pero es
  # fundamental para monitorizar en produccion.
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# Politica de capacidad del cluster: definir que solo usamos Fargate
# Esto evita que alguien pueda lanzar tasks con launch type EC2 por accidente
resource "aws_ecs_cluster_capacity_providers" "shopapi" {
  cluster_name = aws_ecs_cluster.shopapi.name

  # Solo Fargate y Fargate Spot disponibles en este cluster
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  # Estrategia por defecto: usar Fargate standard
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 0
  }
}

# =============================================================================
# CLOUDWATCH LOG GROUP
# =============================================================================

# Log group para centralizar los logs de todos los contenedores de ShopAPI
# El driver awslogs del contenedor envia logs a este grupo automaticamente
resource "aws_cloudwatch_log_group" "ecs_shopapi" {
  name              = "/ecs/${var.project_prefix}"
  retention_in_days = var.log_retention_days

  # NOTA: Si destruyes y vuelves a crear el log group, perdes los logs historicos
  # En produccion considera usar lifecycle { prevent_destroy = true }
}

# =============================================================================
# IAM EXECUTION ROLE
# =============================================================================

# Trust policy: define que entidad puede asumir este rol
# Solo el servicio ecs-tasks puede usarlo (principio de minimo privilegio)
data "aws_iam_policy_document" "ecs_trust_policy" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

# Execution Role: permisos para que ECS gestione la infraestructura del task
# DIFERENCIA CLAVE en el examen:
#   - Execution Role: usado por el AGENTE de ECS (pull de ECR, envio de logs)
#   - Task Role: usado por TU CODIGO para acceder a servicios AWS (S3, DynamoDB)
resource "aws_iam_role" "ecs_execution_role" {
  name               = "${var.project_prefix}-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_trust_policy.json
  description        = "Rol de ejecucion para tareas ECS Fargate de ${var.project_prefix}"
}

# Adjuntar la politica gestionada por AWS que da los permisos minimos necesarios:
#   - ecr:GetAuthorizationToken
#   - ecr:BatchCheckLayerAvailability
#   - ecr:GetDownloadUrlForLayer
#   - ecr:BatchGetImage
#   - logs:CreateLogStream
#   - logs:PutLogEvents
resource "aws_iam_role_policy_attachment" "ecs_execution_role_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# =============================================================================
# ECS TASK DEFINITION
# =============================================================================

# La Task Definition es la "receta" que describe como ejecutar el contenedor:
# - Que imagen usar
# - Cuanta CPU y memoria reservar
# - Como configurar la red
# - Donde enviar los logs
# - Health check del contenedor
resource "aws_ecs_task_definition" "shopapi_api" {
  family = "${var.project_prefix}-api"

  # Fargate requiere awsvpc — cada task obtiene su propia ENI y IP
  network_mode = "awsvpc"

  # Solo compatible con Fargate (no EC2 launch type)
  requires_compatibilities = ["FARGATE"]

  # CPU y memoria a nivel de task (no de contenedor)
  # En Fargate, los valores posibles estan predefinidos por AWS:
  # cpu=256  -> memory puede ser 512, 1024, 2048
  # cpu=512  -> memory puede ser 1024-4096 (en pasos de 1024)
  # cpu=1024 -> memory puede ser 2048-8192 (en pasos de 1024)
  cpu    = tostring(var.task_cpu)
  memory = tostring(var.task_memory)

  # El execution role permite al agente de ECS hacer pull y enviar logs
  execution_role_arn = aws_iam_role.ecs_execution_role.arn

  # Definicion del contenedor en formato JSON
  container_definitions = jsonencode([
    {
      name      = "${var.project_prefix}-api"
      image     = "${aws_ecr_repository.shopapi_api.repository_url}:${var.app_version}"
      essential = true # Si este contenedor falla, el task entero falla

      # Mapeo de puertos — en awsvpc el hostPort debe igualar al containerPort
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
        }
      ]

      # Variables de entorno para la aplicacion
      environment = [
        {
          name  = "APP_ENV"
          value = "production"
        },
        {
          name  = "APP_VERSION"
          value = var.app_version
        }
      ]

      # Configuracion de logs: driver awslogs envia stdout/stderr a CloudWatch
      # El log stream se creara automaticamente con el formato:
      # /ecs/shopapi → shopapi-api/shopapi-api/{task-id}
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_shopapi.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "${var.project_prefix}-api"
        }
      }

      # Health check a nivel de contenedor
      # ECS considera el contenedor HEALTHY si el comando devuelve exit code 0
      # startPeriod: segundos que ECS espera antes de empezar a comprobar
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }

      stopTimeout = 30 # Segundos para SIGTERM antes de SIGKILL
    }
  ])

  # Asegurar que el log group y el role existen antes de crear la task definition
  depends_on = [
    aws_cloudwatch_log_group.ecs_shopapi,
    aws_iam_role_policy_attachment.ecs_execution_role_policy
  ]
}

# =============================================================================
# NULL RESOURCE — DOCKER BUILD + PUSH
# =============================================================================

# Este recurso ejecuta comandos locales para construir y subir la imagen Docker
# Se re-ejecuta cuando cambia la version de la app (var.app_version)
# REQUISITO: Docker debe estar corriendo en la maquina donde se ejecuta Terraform
resource "null_resource" "docker_build_push" {
  # Trigger: se re-ejecuta cuando cambia la version o el URI del repositorio
  triggers = {
    app_version        = var.app_version
    ecr_repository_url = aws_ecr_repository.shopapi_api.repository_url
    app_dir            = var.app_dir
  }

  # Paso 1: Autenticar Docker con ECR
  provisioner "local-exec" {
    command = <<-EOT
      echo "Autenticando Docker con ECR..."
      aws ecr get-login-password \
        --region ${var.aws_region} \
        | docker login \
          --username AWS \
          --password-stdin \
          ${var.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com
      echo "Login exitoso"
    EOT
  }

  # Paso 2: Build de la imagen Docker
  provisioner "local-exec" {
    command = <<-EOT
      echo "Construyendo imagen Docker..."
      docker build \
        --tag ${var.project_prefix}-api:${var.app_version} \
        --tag ${var.project_prefix}-api:latest \
        --build-arg APP_VERSION=${var.app_version} \
        ${var.app_dir}
      echo "Build completado"
    EOT
  }

  # Paso 3: Tag y push a ECR
  provisioner "local-exec" {
    command = <<-EOT
      echo "Subiendo imagen a ECR..."
      docker tag ${var.project_prefix}-api:${var.app_version} \
        ${aws_ecr_repository.shopapi_api.repository_url}:${var.app_version}
      docker tag ${var.project_prefix}-api:latest \
        ${aws_ecr_repository.shopapi_api.repository_url}:latest

      docker push ${aws_ecr_repository.shopapi_api.repository_url}:${var.app_version}
      docker push ${aws_ecr_repository.shopapi_api.repository_url}:latest
      echo "Push completado. URI: ${aws_ecr_repository.shopapi_api.repository_url}:${var.app_version}"
    EOT
  }

  # El ECR repo debe existir antes de poder hacer push
  depends_on = [aws_ecr_repository.shopapi_api]
}
