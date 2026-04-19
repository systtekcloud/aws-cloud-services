# terragrunt/single-az/terragrunt.hcl
#
# Config A: NAT GW solo en AZ-a.
# subnet-private-b enruta su tráfico por NAT-a (cross-AZ).
# Si AZ-a falla → subnet-private-b pierde internet. SPOF.

terraform {
  source = "../_modules/networking"
}

include "root" {
  path = find_in_parent_folders()
}

inputs = {
  nat_ha      = false
  environment = "single-az"
  cidr_vpc    = "10.0.0.0/16"
}
