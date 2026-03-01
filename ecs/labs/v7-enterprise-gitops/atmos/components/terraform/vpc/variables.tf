# Variables del componente VPC — igual que el módulo subyacente
# Los valores vienen del stack YAML (atmos/stacks/dev.yaml, etc.)

variable "environment"             { type = string }
variable "vpc_cidr"                { type = string; default = "10.1.0.0/16" }
variable "availability_zones"      { type = list(string); default = ["eu-west-1a"] }
variable "single_nat_gateway"      { type = bool; default = true }
variable "enable_flow_logs"        { type = bool; default = false }
variable "flow_log_retention_days" { type = number; default = 30 }
