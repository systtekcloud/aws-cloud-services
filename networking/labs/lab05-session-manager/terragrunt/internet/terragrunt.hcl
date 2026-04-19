# SSM via internet — patrón habitual.
# EC2 privada → NAT GW → internet → servicio SSM de AWS.
# La EC2 tiene acceso a internet (curl funciona).
terraform {
  source = "../_modules/networking"
}

include "root" {
  path = find_in_parent_folders()
}

inputs = {
  ssm_mode    = "internet"
  environment = "internet"
}
