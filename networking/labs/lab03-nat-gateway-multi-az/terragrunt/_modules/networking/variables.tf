# _modules/networking/variables.tf

variable "nat_ha" {
  type        = bool
  description = "true = NAT GW en cada AZ (alta disponibilidad). false = NAT GW solo en AZ-a (SPOF)."
}

variable "environment" {
  type        = string
  description = "Nombre del entorno, usado en tags y nombres de recursos. Ej: single-az, multi-az."
}

variable "cidr_vpc" {
  type        = string
  default     = "10.0.0.0/16"
  description = "CIDR block de la VPC."
}

variable "region" {
  type        = string
  default     = "eu-west-1"
  description = "Región AWS donde se despliega el lab."
}
