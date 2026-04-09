variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "lab02-kda"
}

variable "shard_count" {
  description = "Number of shards for the KDS source stream"
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Lab       = "lab02-kinesis-analytics"
    Module    = "data"
    ManagedBy = "terraform"
  }
}
