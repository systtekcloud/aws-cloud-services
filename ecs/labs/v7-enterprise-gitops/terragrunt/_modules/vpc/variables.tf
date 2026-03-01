variable "environment" {
  description = "Nombre del entorno (dev, staging, prod)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block de la VPC"
  type        = string
  default     = "10.1.0.0/16"
}

variable "availability_zones" {
  description = "Lista de AZs donde crear las subnets"
  type        = list(string)
  default     = ["eu-west-1a"]
}

variable "single_nat_gateway" {
  description = "Usar un solo NAT Gateway (true) o uno por AZ (false). true = menos coste, false = más resiliencia"
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Habilitar VPC Flow Logs en CloudWatch para auditoría de red"
  type        = bool
  default     = false
}

variable "flow_log_retention_days" {
  description = "Días de retención de los VPC Flow Logs en CloudWatch"
  type        = number
  default     = 30
}
