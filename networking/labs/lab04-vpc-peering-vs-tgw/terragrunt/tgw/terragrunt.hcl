# Transit Gateway: hub centralizado. N VPCs = N attachments.
# Coste: $0.05/h por attachment (3 attachments = $0.15/h).
terraform {
  source = "../_modules/networking"
}

include "root" {
  path = find_in_parent_folders()
}

inputs = {
  connectivity_mode = "tgw"
  environment       = "tgw"
}
