variable "aws_region"     { type = string; default = "eu-west-1" }
variable "project_prefix" { type = string; default = "shopapi" }
variable "github_org"     { type = string; description = "Tu usuario u organización de GitHub" }
variable "github_repo"    { type = string; description = "Nombre del repositorio (ej: shopapi)" }
