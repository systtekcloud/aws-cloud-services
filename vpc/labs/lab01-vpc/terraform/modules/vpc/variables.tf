variable "vpc_name" {
  description = "Nombre de la VPC (se usa en tags)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block de la VPC"
  type        = string
  default     = "10.10.0.0/16"
}

variable "azs" {
  description = "Lista de Availability Zones a usar"
  type        = list(string)
  default     = ["eu-west-1a", "eu-west-1b"]
}

variable "public_subnets" {
  description = "CIDRs de subnets públicas (una por AZ)"
  type        = list(string)
  default     = ["10.10.1.0/24", "10.10.2.0/24"]
}

variable "private_subnets" {
  description = "CIDRs de subnets privadas"
  type        = list(string)
  default     = ["10.10.11.0/24", "10.10.12.0/24"]
}

variable "isolated_subnets" {
  description = "CIDRs de subnets aisladas (sin ruta a internet)"
  type        = list(string)
  default     = ["10.10.21.0/24", "10.10.22.0/24"]
}

variable "enable_nat_gateway" {
  description = "Crear NAT Gateway (genera coste). Desactivar para entornos de bajo coste."
  type        = bool
  default     = false
}

variable "enable_s3_endpoint" {
  description = "Crear Gateway Endpoint para S3 (gratis)"
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Activar VPC Flow Logs a CloudWatch"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags comunes para todos los recursos"
  type        = map(string)
  default     = {}
}
