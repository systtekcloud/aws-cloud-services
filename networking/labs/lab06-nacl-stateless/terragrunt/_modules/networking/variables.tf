# _modules/networking/variables.tf

variable "environment" {
  type    = string
  default = "lab06"
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}
