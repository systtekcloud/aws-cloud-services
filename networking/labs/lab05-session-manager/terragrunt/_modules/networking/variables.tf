# _modules/networking/variables.tf

variable "ssm_mode" {
  type        = string
  description = <<EOT
Modo de acceso SSM:
  "internet"  → NAT GW + IGW. SSM Agent contacta el servicio via internet.
  "endpoints" → 3 VPC Interface Endpoints. SSM sin internet. Zero egress externo.
EOT

  validation {
    condition     = contains(["internet", "endpoints"], var.ssm_mode)
    error_message = "ssm_mode debe ser 'internet' o 'endpoints'."
  }
}

variable "environment" {
  type        = string
  description = "Nombre del entorno para tags y nombres de recursos."
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}
