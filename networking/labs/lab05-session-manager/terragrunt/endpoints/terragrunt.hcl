# SSM via Interface Endpoints — zero internet.
# EC2 privada → Interface Endpoints (ENIs en la misma subnet) → servicio SSM.
# Sin NAT GW, sin IGW, sin ruta por defecto.
# curl a internet falla. SSM funciona. Esto es lo que demuestra el lab.
terraform {
  source = "../_modules/networking"
}

include "root" {
  path = find_in_parent_folders()
}

inputs = {
  ssm_mode    = "endpoints"
  environment = "endpoints"
}
