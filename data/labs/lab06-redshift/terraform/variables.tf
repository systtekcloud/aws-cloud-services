variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "lab06-redshift"
}

variable "admin_username" {
  description = "Redshift admin username"
  type        = string
  default     = "adminuser"
}

variable "admin_password" {
  description = "Redshift admin password (min 8 chars, uppercase, lowercase, number, special)"
  type        = string
  default     = "Lab06Admin#2024"
  sensitive   = true
}

variable "base_rpu" {
  description = "Base capacity in Redshift Processing Units (RPUs). Min 8 for Serverless."
  type        = number
  default     = 8
}

variable "publicly_accessible" {
  description = "Whether the workgroup endpoint is publicly accessible"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Lab       = "lab06-redshift"
    Module    = "data"
    ManagedBy = "terraform"
  }
}
