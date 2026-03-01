variable "environment" {
  description = "Nombre del entorno (dev, staging, prod)"
  type        = string
}

variable "container_insights" {
  description = "Habilitar Container Insights en el cluster (métricas avanzadas de ECS en CloudWatch)"
  type        = bool
  default     = false
}

variable "capacity_providers" {
  description = "Capacity Providers disponibles en el cluster"
  type        = list(string)
  default     = ["FARGATE", "FARGATE_SPOT"]
}

variable "enable_execute_command" {
  description = "Habilitar ECS Exec para conectar a las tasks via SSM (útil para debugging en prod)"
  type        = bool
  default     = false
}
