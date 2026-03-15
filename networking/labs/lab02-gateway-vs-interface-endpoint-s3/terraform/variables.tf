# =============================================================================
# variables.tf — Inputs del lab
# =============================================================================

variable "prefix" {
  description = "Prefijo para nombres de recursos"
  type        = string
  default     = "lab02"
}

variable "aws_region" {
  description = "Región AWS"
  type        = string
  default     = "eu-west-1"
}

variable "vpc_cidr" {
  description = "CIDR de la VPC principal"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR de la subnet pública — donde vive el NAT Gateway"
  type        = string
  default     = "10.0.0.0/24"
}

variable "subnet_gw_cidr" {
  description = <<-EOT
    CIDR de la subnet privada con Gateway Endpoint.
    La route table de esta subnet tiene una entrada para S3 → Gateway Endpoint.
    El tráfico S3 desde aquí NO pasa por NAT Gateway.
  EOT
  type    = string
  default = "10.0.1.0/24"
}

variable "subnet_nat_cidr" {
  description = <<-EOT
    CIDR de la subnet privada sin Gateway Endpoint.
    La route table de esta subnet solo tiene 0.0.0.0/0 → NAT Gateway.
    Todo el tráfico (incluido S3) pasa por NAT Gateway.
  EOT
  type    = string
  default = "10.0.2.0/24"
}

variable "az" {
  description = "Availability Zone para todos los recursos (lab single-AZ)"
  type        = string
  default     = "eu-west-1a"
}

variable "instance_type" {
  description = "Tipo de instancia EC2"
  type        = string
  default     = "t3.micro"
}

variable "flow_log_retention_days" {
  description = "Días de retención de Flow Logs en CloudWatch (mínimo para ahorrar coste)"
  type        = number
  default     = 1
}
