# =============================================================================
# Lab v1 — ShopAPI en ECS Fargate
# Terraform: Variables de configuracion
# =============================================================================

# =============================================================================
# VARIABLES DE AWS
# =============================================================================

variable "aws_region" {
  type        = string
  description = "Region de AWS donde se desplegaran los recursos"
  default     = "eu-west-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "El formato de la region debe ser valido (ej: eu-west-1, us-east-1)"
  }
}

variable "account_id" {
  type        = string
  description = "ID de la cuenta AWS (12 digitos). Obtener con: aws sts get-caller-identity --query Account --output text"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "El account_id debe ser un numero de 12 digitos"
  }
}

# =============================================================================
# VARIABLES DEL PROYECTO
# =============================================================================

variable "project_prefix" {
  type        = string
  description = "Prefijo usado en el nombre de todos los recursos del proyecto"
  default     = "shopapi"

  validation {
    condition     = length(var.project_prefix) <= 20 && can(regex("^[a-z][a-z0-9-]*$", var.project_prefix))
    error_message = "El prefijo debe ser lowercase, empezar por letra, max 20 caracteres"
  }
}

variable "app_version" {
  type        = string
  description = "Version de la imagen Docker a construir y desplegar (ej: 0.1.0, 1.2.3)"
  default     = "0.1.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.app_version))
    error_message = "La version debe seguir formato semver: MAYOR.MENOR.PARCHE (ej: 0.1.0)"
  }
}

variable "app_dir" {
  type        = string
  description = "Ruta absoluta al directorio de la aplicacion donde esta el Dockerfile"
  default     = "/home/sergi/DevOpsProjects/aws/services/shopapi"
}

# =============================================================================
# VARIABLES DE ECS / FARGATE
# =============================================================================

variable "task_cpu" {
  type        = number
  description = <<-EOT
    CPU reservada para el task en unidades de vCPU x 1024.
    Valores validos en Fargate: 256, 512, 1024, 2048, 4096.
    256 = 0.25 vCPU (minimo permitido por Fargate)
  EOT
  default     = 256

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096], var.task_cpu)
    error_message = "CPU debe ser uno de: 256, 512, 1024, 2048, 4096"
  }
}

variable "task_memory" {
  type        = number
  description = <<-EOT
    Memoria reservada para el task en MB.
    Con cpu=256: valores validos son 512, 1024, 2048.
    Con cpu=512: valores validos son 1024-4096 (en pasos de 1024).
    Consultar: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-cpu-memory-error.html
  EOT
  default     = 512

  validation {
    condition     = var.task_memory >= 512 && var.task_memory <= 30720
    error_message = "Memoria debe estar entre 512 MB y 30720 MB (30 GB)"
  }
}

# =============================================================================
# VARIABLES DE ECR
# =============================================================================

variable "ecr_max_images" {
  type        = number
  description = "Numero maximo de imagenes con tag a mantener en el repositorio ECR (lifecycle policy)"
  default     = 5

  validation {
    condition     = var.ecr_max_images >= 1 && var.ecr_max_images <= 100
    error_message = "El numero maximo de imagenes debe estar entre 1 y 100"
  }
}

# =============================================================================
# VARIABLES DE CLOUDWATCH
# =============================================================================

variable "log_retention_days" {
  type        = number
  description = <<-EOT
    Dias de retencion de logs en CloudWatch Log Group.
    Valores validos: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653.
    0 = sin expiracion (no recomendado por costes).
  EOT
  default     = 30

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.log_retention_days
    )
    error_message = "El valor de retencion debe ser uno de los valores validos de CloudWatch"
  }
}
