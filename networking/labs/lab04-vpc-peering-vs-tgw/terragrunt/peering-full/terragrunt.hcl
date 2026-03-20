# Full mesh: A↔B, B↔C y A↔C. Funciona pero N*(N-1)/2 peerings.
# Para 3 VPCs = 3 peerings. Para 10 VPCs = 45 peerings.
terraform {
  source = "../_modules/networking"
}

include "root" {
  path = find_in_parent_folders()
}

inputs = {
  connectivity_mode = "peering-full"
  environment       = "peering-full"
}
