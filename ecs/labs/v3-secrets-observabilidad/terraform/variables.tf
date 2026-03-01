variable "aws_region" {
  description = "Región AWS del lab"
  type        = string
  default     = "eu-west-1"
}

variable "project_prefix" {
  description = "Prefijo de nombres de recursos"
  type        = string
  default     = "shopapi"
}

variable "app_version" {
  description = "Versión de la imagen a desplegar"
  type        = string
  default     = "0.3.0"
}

variable "task_cpu" {
  description = "CPU de la task en unidades (256 = 0.25 vCPU)"
  type        = string
  default     = "256"
}

variable "task_memory" {
  description = "Memoria de la task en MB"
  type        = string
  default     = "512"
}

variable "desired_count" {
  description = "Número deseado de tasks del service"
  type        = number
  default     = 2
}

variable "log_retention_days" {
  description = "Días de retención de CloudWatch Logs"
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "log_retention_days debe ser un valor válido de CloudWatch."
  }
}

variable "alert_email" {
  description = "Email para recibir alertas de CloudWatch (dejar vacío para no crear suscripción)"
  type        = string
  default     = ""
}
