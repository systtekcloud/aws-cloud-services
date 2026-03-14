variable "aws_region" {
  description = "Región AWS donde desplegar el lab"
  type        = string
  default     = "eu-west-1"
}

variable "project" {
  description = "Nombre del proyecto (usado en tags y nombres de recursos)"
  type        = string
  default     = "db-labs"
}

variable "lab" {
  description = "Identificador del lab"
  type        = string
  default     = "lab01"
}

variable "env" {
  description = "Entorno (lab, dev, prod)"
  type        = string
  default     = "lab"

  validation {
    condition     = contains(["lab", "dev", "staging", "prod"], var.env)
    error_message = "env debe ser: lab, dev, staging, o prod."
  }
}

variable "vpc_cidr" {
  description = "CIDR block de la VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "subnet_public_a_cidr" {
  description = "CIDR subnet pública AZ-a"
  type        = string
  default     = "10.20.1.0/24"
}

variable "subnet_public_b_cidr" {
  description = "CIDR subnet pública AZ-b"
  type        = string
  default     = "10.20.2.0/24"
}

variable "subnet_db_a_cidr" {
  description = "CIDR subnet privada DB AZ-a (para RDS Primary)"
  type        = string
  default     = "10.20.11.0/24"
}

variable "subnet_db_b_cidr" {
  description = "CIDR subnet privada DB AZ-b (para RDS Standby/Replica)"
  type        = string
  default     = "10.20.12.0/24"
}

variable "subnet_app_a_cidr" {
  description = "CIDR subnet privada app AZ-a (para EC2)"
  type        = string
  default     = "10.20.21.0/24"
}

variable "rds_instance_class" {
  description = "Clase de instancia RDS"
  type        = string
  default     = "db.t3.micro"

  validation {
    condition     = can(regex("^db\\.", var.rds_instance_class))
    error_message = "La clase de instancia debe comenzar con 'db.' (ej: db.t3.micro)."
  }
}

variable "rds_engine_version" {
  description = "Versión del motor MySQL"
  type        = string
  default     = "8.0"
}

variable "rds_storage_gb" {
  description = "Almacenamiento en GB para la instancia RDS"
  type        = number
  default     = 20

  validation {
    condition     = var.rds_storage_gb >= 20 && var.rds_storage_gb <= 65536
    error_message = "El storage debe estar entre 20 GB y 65536 GB."
  }
}

variable "rds_db_name" {
  description = "Nombre de la base de datos inicial"
  type        = string
  default     = "labdb"
}

variable "enable_multi_az" {
  description = "Habilitar Multi-AZ (standby en segunda AZ). Dobla el coste."
  type        = bool
  default     = false
}

variable "enable_read_replica" {
  description = "Crear una Read Replica en AZ-b"
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "Días de retención de backups automáticos (0 = deshabilitado)"
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_period >= 0 && var.backup_retention_period <= 35
    error_message = "backup_retention_period debe estar entre 0 y 35 días."
  }
}
