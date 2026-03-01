variable "aws_region"   { type = string; default = "eu-west-1" }
variable "project"      { type = string; default = "ec2lab" }
variable "environment"  { type = string; default = "lab" }

variable "asg_name" {
  description = "Nombre del ASG de v1"
  type        = string
}

variable "tg_blue_arn" {
  description = "ARN del Target Group Blue (v1)"
  type        = string
}

variable "alb_listener_arn" {
  description = "ARN del Listener del ALB (v1)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID de v1"
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnets privadas de app (v1)"
  type        = list(string)
}

variable "launch_template_id" {
  description = "ID del Launch Template de v1"
  type        = string
}

variable "asg_cpu_target" {
  description = "CPU target para Target Tracking"
  type        = number
  default     = 60
}

variable "warm_pool_min_size" {
  description = "Instancias mínimas en el Warm Pool"
  type        = number
  default     = 2
}
