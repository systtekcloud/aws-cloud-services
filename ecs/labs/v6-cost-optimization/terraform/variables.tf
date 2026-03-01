variable "aws_region" {
  description = "Región AWS"
  type        = string
  default     = "eu-west-1"
}

variable "project_prefix" {
  description = "Prefijo de todos los recursos"
  type        = string
  default     = "shopapi"
}

variable "app_version" {
  description = "Versión de la imagen Docker ARM64"
  type        = string
  default     = "0.6.0-arm64"
}

variable "task_cpu" {
  description = "CPU de la task (unidades Fargate)"
  type        = number
  default     = 1024

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096], var.task_cpu)
    error_message = "task_cpu debe ser uno de: 256, 512, 1024, 2048, 4096."
  }
}

variable "task_memory" {
  description = "Memoria de la task en MB"
  type        = number
  default     = 2048
}

variable "api_desired_count" {
  description = "Número deseado de tasks de la API"
  type        = number
  default     = 2
}

variable "worker_desired_count" {
  description = "Número deseado de tasks del Worker"
  type        = number
  default     = 1
}

variable "enable_vpc_endpoints" {
  description = "Crear VPC Endpoints privados para ECR/CloudWatch/Secrets"
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Días de retención de logs en CloudWatch"
  type        = number
  default     = 14
}
