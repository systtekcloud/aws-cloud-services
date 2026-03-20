# Demuestra la no-transitividad: A↔B y B↔C configurados,
# pero A no puede llegar a C.
terraform {
  source = "../_modules/networking"
}

include "root" {
  path = find_in_parent_folders()
}

inputs = {
  connectivity_mode = "peering-partial"
  environment       = "peering-partial"
}
