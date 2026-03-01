variable "environment"           { type = string }
variable "vpc_id"                { type = string }
variable "public_subnet_ids"     { type = list(string) }
variable "deletion_protection"   { type = bool; default = false }
variable "health_check_path"     { type = string; default = "/health" }
variable "health_check_interval" { type = number; default = 30 }
variable "health_check_timeout"  { type = number; default = 5 }
variable "healthy_threshold"     { type = number; default = 2 }
variable "unhealthy_threshold"   { type = number; default = 3 }
variable "deregistration_delay"  { type = number; default = 60 }
variable "access_logs_enabled"   { type = bool; default = false }
variable "access_logs_bucket"    { type = string; default = "" }
variable "access_logs_prefix"    { type = string; default = "alb" }
