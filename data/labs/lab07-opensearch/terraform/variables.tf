variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "lab07"
}

variable "domain_name" {
  description = "OpenSearch domain name"
  type        = string
  default     = "lab07-opensearch"
}

variable "engine_version" {
  description = "OpenSearch engine version"
  type        = string
  default     = "OpenSearch_2.11"
}

variable "instance_type" {
  description = "OpenSearch instance type (t3.small.search for labs)"
  type        = string
  default     = "t3.small.search"
}

variable "volume_size_gb" {
  description = "EBS volume size in GB"
  type        = number
  default     = 10
}

variable "master_user_name" {
  description = "OpenSearch master username"
  type        = string
  default     = "admin"
}

variable "master_user_password" {
  description = "OpenSearch master password"
  type        = string
  default     = "Lab07Admin#2024"
  sensitive   = true
}

variable "allowed_cidr" {
  description = "CIDR allowed to access OpenSearch (your public IP + /32)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Lab       = "lab07-opensearch"
    Module    = "data"
    ManagedBy = "terraform"
  }
}
