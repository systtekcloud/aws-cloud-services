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
  description = "Nombre del bucket S3 donde Firehose escribe el raw/"
  type        = string
}

variable "data_lake_bucket_arn" {
  type = string
}

variable "common_tags" {
  type    = map(string)
  default = {}
}

variable "kds_shard_count" {
  description = "Número de shards de Kinesis Data Stream (1 shard = 1MB/s entrada, 2MB/s salida)"
  type        = number
  default     = 1
}

variable "firehose_buffer_seconds" {
  description = "Buffer de Firehose en segundos antes de escribir a S3"
  type        = number
  default     = 60
}

variable "firehose_buffer_mb" {
  description = "Buffer de Firehose en MB antes de escribir a S3"
  type        = number
  default     = 5
}
