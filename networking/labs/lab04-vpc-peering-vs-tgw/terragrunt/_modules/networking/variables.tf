# _modules/networking/variables.tf

variable "connectivity_mode" {
  type        = string
  description = <<EOT
Modo de conectividad entre las 3 VPCs:
  "peering-partial" → A↔B + B↔C. Demuestra no-transitividad (A no llega a C).
  "peering-full"    → A↔B + B↔C + A↔C. Full mesh funcional pero no escalable.
  "tgw"             → Transit Gateway hub. N attachments en lugar de N*(N-1)/2.
EOT

  validation {
    condition     = contains(["peering-partial", "peering-full", "tgw"], var.connectivity_mode)
    error_message = "connectivity_mode debe ser peering-partial, peering-full o tgw."
  }
}

variable "environment" {
  type        = string
  description = "Nombre del entorno para tags y nombres de recursos."
}

variable "region" {
  type    = string
  default = "eu-west-1"
}
