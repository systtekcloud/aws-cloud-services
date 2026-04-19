# terragrunt/multi-az/terragrunt.hcl
#
# Config B: NAT GW en AZ-a Y AZ-b.
# Cada subnet privada tiene su propio NAT en la misma AZ.
# Si AZ-a falla → subnet-private-b sigue funcionando via NAT-b. HA.

terraform {
  source = "../_modules/networking"
}

include "root" {
  path = find_in_parent_folders()
}

inputs = {
  nat_ha      = true
  environment = "multi-az"
  cidr_vpc    = "10.0.0.0/16"
}
