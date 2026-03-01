variable "environment" {
  description = "Nombre del entorno (dev, staging, prod)"
  type        = string
}

variable "service_name" {
  description = "Nombre del servicio ECS"
  type        = string
  default     = "shopapi-api"
}

variable "cluster_name" {
  description = "Nombre del cluster ECS donde se despliega el servicio"
  type        = string
}

variable "cluster_arn" {
  description = "ARN del cluster ECS"
  type        = string
}

variable "vpc_id" {
  description = "ID de la VPC"
  type        = string
}

variable "private_subnet_ids" {
  description = "IDs de las subnets privadas donde corren las tasks ECS"
  type        = list(string)
}

variable "target_group_arn" {
  description = "ARN del Target Group del ALB"
  type        = string
}

variable "alb_security_group_id" {
  description = "ID del Security Group del ALB (para permitir tráfico desde el ALB a las tasks)"
  type        = string
}

variable "container_image" {
  description = "Imagen Docker completa (registry/repo:tag)"
  type        = string
}

variable "container_port" {
  description = "Puerto en el que escucha la aplicación dentro del contenedor"
  type        = number
  default     = 8080
}

variable "cpu" {
  description = "CPU de la Task Definition en unidades Fargate (256, 512, 1024, 2048, 4096)"
  type        = number
  default     = 1024

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096], var.cpu)
    error_message = "cpu debe ser uno de: 256, 512, 1024, 2048, 4096."
  }
}

variable "memory" {
  description = "Memoria de la Task Definition en MB"
  type        = number
  default     = 2048
}

variable "desired_count" {
  description = "Número deseado de tasks en ejecución"
  type        = number
  default     = 2
}

variable "min_tasks" {
  description = "Mínimo de tasks para Application Auto Scaling"
  type        = number
  default     = 1
}

variable "max_tasks" {
  description = "Máximo de tasks para Application Auto Scaling"
  type        = number
  default     = 10
}

variable "capacity_provider_strategy" {
  description = "Estrategia de Capacity Providers (mezcla FARGATE/FARGATE_SPOT)"
  type = list(object({
    capacity_provider = string
    weight            = number
    base              = number
  }))
  default = [
    {
      capacity_provider = "FARGATE"
      weight            = 1
      base              = 1
    }
  ]
}

variable "log_retention_days" {
  description = "Días de retención de logs en CloudWatch"
  type        = number
  default     = 30
}

variable "scale_up_cpu_threshold" {
  description = "Porcentaje de CPU que activa el scale-out"
  type        = number
  default     = 60
}

variable "scale_down_cpu_threshold" {
  description = "Porcentaje de CPU que activa el scale-in (no usado en Target Tracking, referencial)"
  type        = number
  default     = 25
}

variable "enable_scheduled_scaling" {
  description = "Activar scale-down nocturno con EventBridge Scheduler (solo dev)"
  type        = bool
  default     = false
}

variable "scale_down_cron" {
  description = "Expresión cron de EventBridge para el scale-down (p. ej. 'cron(0 20 * * ? *)')"
  type        = string
  default     = ""
}

variable "scale_up_cron" {
  description = "Expresión cron de EventBridge para el scale-up (p. ej. 'cron(0 7 * * ? *)')"
  type        = string
  default     = ""
}

variable "ops_email" {
  description = "Email del equipo de operaciones para alarmas CloudWatch (solo prod)"
  type        = string
  default     = ""
}

variable "alarm_5xx_threshold" {
  description = "Porcentaje de errores 5xx del ALB que dispara alarma"
  type        = number
  default     = 5
}

variable "alarm_latency_p99_seconds" {
  description = "Latencia P99 en segundos que dispara alarma"
  type        = number
  default     = 1.0
}

variable "deployment_circuit_breaker_enabled" {
  description = "Activar el Circuit Breaker de ECS (detecta deploys fallidos)"
  type        = bool
  default     = true
}

variable "deployment_circuit_breaker_rollback" {
  description = "Hacer rollback automático si el Circuit Breaker se activa"
  type        = bool
  default     = true
}

variable "deployment_maximum_percent" {
  description = "Porcentaje máximo de tasks durante un rolling update"
  type        = number
  default     = 200
}

variable "deployment_minimum_healthy_percent" {
  description = "Porcentaje mínimo de tasks healthy durante un rolling update"
  type        = number
  default     = 100
}
