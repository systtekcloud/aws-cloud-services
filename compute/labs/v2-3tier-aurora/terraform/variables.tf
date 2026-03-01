################################################################################
# Lab EC2 v2 — Variables Terraform
# Extiende v1 con Aurora, ElastiCache y Secrets Manager
################################################################################

variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "project" {
  type    = string
  default = "ec2lab"
}

variable "environment" {
  type    = string
  default = "lab"
}

# ── Importados de v1 (outputs o variables) ────────────────────────────────────

variable "vpc_id" {
  description = "VPC ID creada en v1"
  type        = string
}

variable "private_app_subnet_ids" {
  description = "Subnets privadas de app de v1 (para extraer AZs)"
  type        = list(string)
}

variable "ec2_sg_id" {
  description = "SG de las instancias EC2 de v1 (source para Aurora y Redis)"
  type        = string
}

variable "asg_name" {
  description = "Nombre del ASG de v1 (para Instance Refresh)"
  type        = string
  default     = ""
}

variable "s3_bucket_name" {
  description = "Bucket S3 de artefactos de v1"
  type        = string
  default     = ""
}

# ── DB Subnets ────────────────────────────────────────────────────────────────

variable "db_subnet_cidrs" {
  description = "CIDRs para las subnets de base de datos"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24", "10.0.23.0/24"]
}

# ── Aurora ────────────────────────────────────────────────────────────────────

variable "db_instance_class" {
  description = "Tipo de instancia Aurora (mínimo db.t3.medium para Multi-AZ)"
  type        = string
  default     = "db.t3.medium"
}

variable "db_name" {
  description = "Nombre de la base de datos"
  type        = string
  default     = "shopdb"
}

variable "aurora_engine_version" {
  description = "Versión de Aurora MySQL"
  type        = string
  default     = "8.0.mysql_aurora.3.04.0"
}

# ── ElastiCache ───────────────────────────────────────────────────────────────

variable "redis_node_type" {
  description = "Tipo de nodo ElastiCache Redis"
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_num_clusters" {
  description = "Número de nodos Redis (1 primary + N replicas)"
  type        = number
  default     = 2
}
