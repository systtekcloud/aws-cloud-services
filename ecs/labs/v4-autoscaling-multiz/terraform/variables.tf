variable "aws_region"      { type = string; default = "eu-west-1" }
variable "project_prefix"  { type = string; default = "shopapi" }
variable "app_version"     { type = string; default = "0.4.0" }

variable "subnet_cidr_public_c"  { type = string; default = "10.0.3.0/24" }
variable "subnet_cidr_private_c" { type = string; default = "10.0.13.0/24" }

variable "api_min_tasks"          { type = number; default = 2 }
variable "api_max_tasks"          { type = number; default = 20 }
variable "api_alb_target_value"   { type = number; default = 500 }
variable "api_black_friday_min"   { type = number; default = 10 }

variable "worker_desired_count"    { type = number; default = 1 }
variable "worker_min_tasks"        { type = number; default = 0 }
variable "worker_max_tasks"        { type = number; default = 10 }
variable "sqs_messages_per_task"   { type = number; default = 50 }
