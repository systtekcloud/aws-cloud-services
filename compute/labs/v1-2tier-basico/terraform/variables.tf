################################################################################
# Lab EC2 v1 — Variables Terraform
# 2-tier básico: VPC + ALB + ASG
################################################################################

variable "aws_region" {
  description = "Región AWS donde desplegar el lab"
  type        = string
  default     = "eu-west-1"
}

variable "project" {
  description = "Nombre del proyecto para tags y naming"
  type        = string
  default     = "ec2lab"
}

variable "environment" {
  description = "Entorno (lab, dev, prod)"
  type        = string
  default     = "lab"
}

# ── VPC ──────────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block de la VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Lista de AZs a usar (vacío = auto-detectar primeras 2)"
  type        = list(string)
  default     = []
}

variable "public_subnets_cidrs" {
  description = "CIDRs de subnets públicas (una por AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnets_cidrs" {
  description = "CIDRs de subnets privadas (una por AZ)"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

variable "enable_nat_gateway" {
  description = "Crear NAT Gateways (coste ~0.05€/h por NAT)"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Usar un solo NAT Gateway (ahorra coste en labs)"
  type        = bool
  default     = false
}

# ── EC2 / ASG ────────────────────────────────────────────────────────────────

variable "instance_type" {
  description = "Tipo de instancia EC2"
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "Nombre del key pair para acceso SSH (vacío = sin key pair)"
  type        = string
  default     = ""
}

variable "app_port" {
  description = "Puerto en el que escucha la aplicación"
  type        = number
  default     = 8080
}

variable "asg_min_size" {
  description = "Número mínimo de instancias en el ASG"
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Número máximo de instancias en el ASG"
  type        = number
  default     = 6
}

variable "asg_desired_capacity" {
  description = "Número deseado de instancias al arrancar"
  type        = number
  default     = 2
}

variable "asg_cpu_target" {
  description = "Porcentaje de CPU objetivo para Target Tracking"
  type        = number
  default     = 60
}

# ── S3 ───────────────────────────────────────────────────────────────────────

variable "s3_bucket_name" {
  description = "Nombre del bucket S3 para artefactos (debe ser único globalmente)"
  type        = string
  default     = ""
}
