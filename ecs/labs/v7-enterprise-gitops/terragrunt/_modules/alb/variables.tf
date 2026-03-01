variable "environment" {
  description = "Nombre del entorno (dev, staging, prod)"
  type        = string
}

variable "vpc_id" {
  description = "ID de la VPC donde se desplegará el ALB"
  type        = string
}

variable "public_subnet_ids" {
  description = "Lista de IDs de las subnets públicas para el ALB"
  type        = list(string)
}

variable "deletion_protection" {
  description = "Protección contra el borrado accidental del ALB (activar en prod)"
  type        = bool
  default     = false
}

variable "health_check_path" {
  description = "Ruta HTTP del endpoint de health check"
  type        = string
  default     = "/health"
}

variable "health_check_interval" {
  description = "Intervalo en segundos entre health checks"
  type        = number
  default     = 30
}

variable "health_check_timeout" {
  description = "Timeout en segundos del health check"
  type        = number
  default     = 5
}

variable "healthy_threshold" {
  description = "Checks OK consecutivos para marcar un target como healthy"
  type        = number
  default     = 2
}

variable "unhealthy_threshold" {
  description = "Checks fallidos consecutivos para marcar un target como unhealthy"
  type        = number
  default     = 3
}

variable "deregistration_delay" {
  description = "Segundos que espera el ALB antes de eliminar un target deregistrado"
  type        = number
  default     = 60
}

variable "access_logs_enabled" {
  description = "Habilitar volcado de access logs en S3"
  type        = bool
  default     = false
}

variable "access_logs_bucket" {
  description = "Nombre del bucket S3 para los access logs (requerido si access_logs_enabled=true)"
  type        = string
  default     = ""
}

variable "access_logs_prefix" {
  description = "Prefijo en el bucket S3 para los access logs"
  type        = string
  default     = "alb"
}
