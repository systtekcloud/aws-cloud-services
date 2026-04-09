variable "name_prefix" {
  description = "Prefijo para todos los recursos (proyecto-entorno)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "common_tags" {
  description = "Tags comunes a todos los recursos"
  type        = map(string)
  default     = {}
}

variable "lifecycle_transition_days" {
  description = "Días hasta mover objetos a Glacier Instant Retrieval"
  type        = number
  default     = 90
}

variable "lifecycle_expiration_days" {
  description = "Días hasta expirar objetos en curated/"
  type        = number
  default     = 365
}
