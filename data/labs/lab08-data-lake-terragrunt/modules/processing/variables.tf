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
  description = "Nombre de la base de datos en Glue Data Catalog"
  type        = string
}

variable "glue_role_arn" {
  description = "ARN del IAM role para Glue Crawlers y ETL Jobs"
  type        = string
}

variable "common_tags" {
  type    = map(string)
  default = {}
}

variable "glue_worker_type" {
  description = "Tipo de worker Glue: G.1X (4 vCPU, 16GB) o G.2X (8 vCPU, 32GB)"
  type        = string
  default     = "G.1X"
}

variable "glue_num_workers" {
  description = "Número de workers para el ETL Job"
  type        = number
  default     = 2
}

variable "emr_cpu_max" {
  description = "CPU máxima para EMR Serverless (vCPU)"
  type        = string
  default     = "8 vCPU"
}

variable "emr_memory_max" {
  description = "Memoria máxima para EMR Serverless"
  type        = string
  default     = "16 GB"
}
