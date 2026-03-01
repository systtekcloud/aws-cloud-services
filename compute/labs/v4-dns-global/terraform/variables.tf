variable "aws_region"  { type = string; default = "eu-west-1" }
variable "project"     { type = string; default = "ec2lab" }
variable "environment" { type = string; default = "lab" }

variable "alb_arn" {
  description = "ARN del ALB de v1"
  type        = string
}

variable "alb_dns_name" {
  description = "DNS name del ALB de v1"
  type        = string
}

variable "alb_zone_id" {
  description = "Canonical Hosted Zone ID del ALB (para Route53 Alias)"
  type        = string
}

variable "tg_arn" {
  description = "ARN del Target Group principal (v1)"
  type        = string
}

variable "alb_sg_id" {
  description = "SG del ALB (para añadir regla 443)"
  type        = string
}

variable "domain" {
  description = "Dominio raíz (ej: systtekcloud.dev)"
  type        = string
  default     = "systtekcloud.dev"
}

variable "subdomain" {
  description = "Subdominio de la app"
  type        = string
  default     = "app"
}

variable "hosted_zone_id" {
  description = "ID de la Hosted Zone en Route53"
  type        = string
}
