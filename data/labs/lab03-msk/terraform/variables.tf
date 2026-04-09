variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "lab03-msk"
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Lab       = "lab03-msk"
    Module    = "data"
    ManagedBy = "terraform"
  }
}
