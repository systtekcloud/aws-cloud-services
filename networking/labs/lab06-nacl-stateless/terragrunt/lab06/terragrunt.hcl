# terragrunt/lab06/terragrunt.hcl
#
# Entorno único del lab. No hay variable de modo —
# la manipulación del NACL ocurre en runtime via validate.sh.

terraform {
  source = "../_modules/networking"
}

include "root" {
  path = find_in_parent_folders()
}

inputs = {
  environment = "lab06"
  vpc_cidr    = "10.0.0.0/16"
}
