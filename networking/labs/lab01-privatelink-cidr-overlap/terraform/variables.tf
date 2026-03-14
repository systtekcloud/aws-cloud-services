# =============================================================================
# variables.tf — Inputs del lab
# =============================================================================

variable "prefix" {
  description = "Prefijo para nombres de recursos"
  type        = string
  default     = "lab01"
}

variable "aws_region" {
  description = "Región AWS"
  type        = string
  default     = "eu-west-1"
}

variable "vpc_cidr" {
  description = <<-EOT
    CIDR de las VPCs. Ambas VPCs usan el mismo CIDR para demostrar que
    VPC Peering es imposible con CIDRs solapados y PrivateLink no lo requiere.
  EOT
  type    = string
  default = "10.0.0.0/16"
}

variable "vpc_a_subnet_cidr" {
  description = "CIDR de la subnet pública en VPC-A (consumer)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "vpc_b_subnet_cidr" {
  description = "CIDR de la subnet privada en VPC-B (provider + NLB)"
  type        = string
  default     = "10.0.2.0/24"
}

variable "az" {
  description = "Availability Zone para todos los recursos (lab single-AZ)"
  type        = string
  default     = "eu-west-1a"
}

variable "instance_type" {
  description = "Tipo de instancia EC2 (t3.micro para mantener coste bajo)"
  type        = string
  default     = "t3.micro"
}

variable "http_port" {
  description = "Puerto del servidor HTTP del provider (VPC-B)"
  type        = number
  default     = 8080
}
