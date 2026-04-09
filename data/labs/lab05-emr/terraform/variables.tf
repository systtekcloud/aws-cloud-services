variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "lab05-emr"
}

variable "emr_release_label" {
  description = "EMR Serverless release label"
  type        = string
  default     = "emr-7.1.0"
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Lab       = "lab05-emr"
    Module    = "data"
    ManagedBy = "terraform"
  }
}
