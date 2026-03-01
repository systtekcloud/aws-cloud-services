variable "environment"           { type = string }
variable "service_name"          { type = string; default = "shopapi-api" }
variable "cluster_name"          { type = string }
variable "cluster_arn"           { type = string }
variable "vpc_id"                { type = string }
variable "private_subnet_ids"    { type = list(string) }
variable "target_group_arn"      { type = string }
variable "alb_security_group_id" { type = string }
variable "container_image"       { type = string }
variable "container_port"        { type = number; default = 8080 }
variable "cpu"                   { type = number; default = 1024 }
variable "memory"                { type = number; default = 2048 }
variable "desired_count"         { type = number; default = 2 }
variable "min_tasks"             { type = number; default = 1 }
variable "max_tasks"             { type = number; default = 10 }

variable "capacity_provider_strategy" {
  type = list(object({
    capacity_provider = string
    weight            = number
    base              = number
  }))
  default = [{ capacity_provider = "FARGATE", weight = 1, base = 1 }]
}

variable "log_retention_days"                 { type = number; default = 30 }
variable "scale_up_cpu_threshold"             { type = number; default = 60 }
variable "scale_down_cpu_threshold"           { type = number; default = 25 }
variable "enable_scheduled_scaling"           { type = bool; default = false }
variable "scale_down_cron"                    { type = string; default = "" }
variable "scale_up_cron"                      { type = string; default = "" }
variable "ops_email"                          { type = string; default = "" }
variable "alarm_5xx_threshold"                { type = number; default = 5 }
variable "alarm_latency_p99_seconds"          { type = number; default = 1.0 }
variable "deployment_circuit_breaker_enabled"  { type = bool; default = true }
variable "deployment_circuit_breaker_rollback" { type = bool; default = true }
variable "deployment_maximum_percent"         { type = number; default = 200 }
variable "deployment_minimum_healthy_percent" { type = number; default = 100 }
