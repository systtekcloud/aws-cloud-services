variable "environment"            { type = string }
variable "container_insights"     { type = bool; default = false }
variable "capacity_providers"     { type = list(string); default = ["FARGATE", "FARGATE_SPOT"] }
variable "enable_execute_command" { type = bool; default = false }
