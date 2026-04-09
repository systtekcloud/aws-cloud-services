variable "name_prefix" {
  type = string
}

variable "region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "data_lake_bucket_id" {
  type = string
}

variable "data_lake_bucket_arn" {
  type = string
}

variable "glue_database_name" {
  description = "Nombre de la base de datos en Glue Data Catalog (para Spectrum)"
  type        = string
}

variable "common_tags" {
  type    = map(string)
  default = {}
}

variable "redshift_base_capacity" {
  description = "Capacidad base en Redshift Processing Units (1 RPU = 8 vCPU, 64 GB RAM). Mínimo 8."
  type        = number
  default     = 8
}

variable "redshift_admin_user" {
  description = "Usuario administrador del namespace Redshift"
  type        = string
  default     = "admin"
}

variable "redshift_admin_password" {
  description = "Contraseña del admin de Redshift (min 8 chars, uppercase, lowercase, number)"
  type        = string
  sensitive   = true
  default     = "Lab08Admin2024!"
}
