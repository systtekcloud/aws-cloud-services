variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "lab01-kinesis"
}

variable "shard_count" {
  description = "Number of shards for the KDS stream"
  type        = number
  default     = 2
}

variable "retention_hours" {
  description = "KDS retention period in hours (24–8760)"
  type        = number
  default     = 24

  validation {
    condition     = var.retention_hours >= 24 && var.retention_hours <= 8760
    error_message = "Retention must be between 24 and 8760 hours."
  }
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Lab       = "lab01-kinesis"
    Module    = "data"
    ManagedBy = "terraform"
  }
}
