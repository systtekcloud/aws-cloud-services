variable "name_prefix" {
  type = string
}

variable "region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "data_lake_bucket_arn" {
  description = "ARN del bucket S3 del data lake (para Lake Formation)"
  type        = string
}

variable "data_lake_bucket_id" {
  description = "Nombre del bucket S3"
  type        = string
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
