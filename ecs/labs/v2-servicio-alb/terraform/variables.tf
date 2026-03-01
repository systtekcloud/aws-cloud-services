################################################################################
# Lab v2 ShopAPI — Variables de Terraform
################################################################################

################################################################################
# Variables generales
################################################################################

variable "aws_region" {
  description = "Región AWS donde se despliegan los recursos"
  type        = string
  default     = "eu-west-1"
}

################################################################################
# Variables de red (VPC)
################################################################################

variable "vpc_cidr" {
  description = "CIDR block de la VPC principal"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "El valor de vpc_cidr debe ser un CIDR válido (ej: 10.0.0.0/16)."
  }
}

variable "availability_zones" {
  description = <<EOT
Lista de zonas de disponibilidad a usar.
Si se deja vacía, se usan automáticamente las 2 primeras AZs disponibles
en la región mediante un data source.

Ejemplo: ["eu-west-1a", "eu-west-1b"]
EOT
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.availability_zones) == 0 || length(var.availability_zones) >= 2
    error_message = "Debe especificar 0 (automático) o al menos 2 zonas de disponibilidad."
  }
}

variable "public_subnet_cidrs" {
  description = <<EOT
Lista de CIDRs para las subnets públicas.
Debe tener el mismo número de elementos que availability_zones (o 2 si es automático).
Las subnets públicas alojan el ALB y el NAT Gateway.
EOT
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) >= 2
    error_message = "Debe especificar al menos 2 CIDRs de subnets públicas para el ALB."
  }
}

variable "private_subnet_cidrs" {
  description = <<EOT
Lista de CIDRs para las subnets privadas.
Debe tener el mismo número de elementos que availability_zones (o 2 si es automático).
Las subnets privadas alojan las tasks ECS Fargate.
EOT
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) >= 2
    error_message = "Debe especificar al menos 2 CIDRs de subnets privadas para las tasks ECS."
  }
}

################################################################################
# Variables de la aplicación
################################################################################

variable "app_version" {
  description = "Versión de la aplicación. Se inyecta como variable de entorno APP_VERSION en las tasks."
  type        = string
  default     = "0.1.0"
}

variable "container_port" {
  description = "Puerto en el que la aplicación escucha dentro del contenedor"
  type        = number
  default     = 8080

  validation {
    condition     = var.container_port > 0 && var.container_port < 65536
    error_message = "El puerto del contenedor debe estar entre 1 y 65535."
  }
}

variable "container_name" {
  description = "Nombre del contenedor dentro de la Task Definition"
  type        = string
  default     = "shopapi-api"
}

################################################################################
# Variables de ECS
################################################################################

variable "cluster_name" {
  description = "Nombre del cluster ECS existente (creado en Lab v1)"
  type        = string
  default     = "shopapi-cluster"
}

variable "task_family" {
  description = "Familia de la Task Definition de ECS"
  type        = string
  default     = "shopapi-api"
}

variable "ecr_repository_name" {
  description = "Nombre del repositorio ECR que contiene la imagen de la aplicación"
  type        = string
  default     = "shopapi/api"
}

variable "task_cpu" {
  description = <<EOT
CPU reservada para la task en unidades de CPU de Fargate.
Valores válidos para Fargate: 256, 512, 1024, 2048, 4096
(256 = 0.25 vCPU)
EOT
  type        = string
  default     = "256"

  validation {
    condition     = contains(["256", "512", "1024", "2048", "4096"], var.task_cpu)
    error_message = "task_cpu debe ser uno de: 256, 512, 1024, 2048, 4096."
  }
}

variable "task_memory" {
  description = <<EOT
Memoria reservada para la task en MiB.
Debe ser compatible con el valor de task_cpu:
  256 CPU → 512-2048 MB (múltiplos de 512)
  512 CPU → 1024-4096 MB (múltiplos de 1024)
  1024 CPU → 2048-8192 MB (múltiplos de 1024)
EOT
  type        = string
  default     = "512"
}

variable "desired_count" {
  description = <<EOT
Número deseado de tasks (réplicas) del ECS Service.
Con 2 tasks y maximumPercent=200, el rolling update puede lanzar hasta 4 tasks.
EOT
  type        = number
  default     = 2

  validation {
    condition     = var.desired_count >= 1
    error_message = "desired_count debe ser al menos 1."
  }
}

################################################################################
# Variables de despliegue (rolling update)
################################################################################

variable "health_check_grace_period" {
  description = <<EOT
Tiempo en segundos que ECS espera antes de empezar a comprobar el health
del ALB después de iniciar una task. Necesario para que la app arranque.
Ajustar según el tiempo de arranque de la aplicación.
EOT
  type        = number
  default     = 60

  validation {
    condition     = var.health_check_grace_period >= 0 && var.health_check_grace_period <= 1800
    error_message = "health_check_grace_period debe estar entre 0 y 1800 segundos."
  }
}

variable "maximum_percent" {
  description = <<EOT
Porcentaje máximo de tasks permitidas durante un rolling update.
Fórmula: max_tasks = ceil(desired_count * maximum_percent / 100)
Ejemplo con desired=2 y maximum=200: máximo 4 tasks durante el update.
EOT
  type        = number
  default     = 200

  validation {
    condition     = var.maximum_percent >= 100
    error_message = "maximum_percent debe ser al menos 100."
  }
}

variable "minimum_healthy_percent" {
  description = <<EOT
Porcentaje mínimo de tasks healthy que deben existir durante un rolling update.
Fórmula: min_tasks = floor(desired_count * minimum_healthy_percent / 100)
Ejemplo con desired=2 y minimum=100: mínimo 2 tasks healthy en todo momento.
Con minimum=0 se permite downtime durante el update.
EOT
  type        = number
  default     = 100

  validation {
    condition     = var.minimum_healthy_percent >= 0 && var.minimum_healthy_percent <= 100
    error_message = "minimum_healthy_percent debe estar entre 0 y 100."
  }
}
