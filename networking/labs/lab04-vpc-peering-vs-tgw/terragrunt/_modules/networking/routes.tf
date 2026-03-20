# _modules/networking/routes.tf
#
# Este fichero es el núcleo del lab: define cómo llega el tráfico
# entre VPCs según el connectivity_mode.
#
# Reglas por modo:
#
# peering-partial:
#   VPC-A: conoce VPC-B (via pcx A↔B). NO conoce VPC-C.
#   VPC-B: conoce VPC-A y VPC-C (via pcx A↔B y B↔C). Conoce internet (NAT GW).
#   VPC-C: conoce VPC-B (via pcx B↔C). NO conoce VPC-A.
#   → A no puede llegar a C: SPOF de no-transitividad demostrado.
#
# peering-full:
#   VPC-A: conoce VPC-B y VPC-C (via pcx A↔B y A↔C).
#   VPC-B: conoce VPC-A y VPC-C (via pcx A↔B y B↔C).
#   VPC-C: conoce VPC-A y VPC-B (via pcx A↔C y B↔C).
#   → Full mesh funcionando. Pero 3 peerings para 3 VPCs (N*(N-1)/2).
#
# tgw:
#   Todas las VPCs conocen todas las demás via TGW (route propagation automática).
#   VPC-A y VPC-C conocen internet via VPC-B → TGW → NAT GW de B.

locals {
  is_peering      = startswith(var.connectivity_mode, "peering")
  is_peering_full = var.connectivity_mode == "peering-full"
  is_tgw          = var.connectivity_mode == "tgw"
}

# ────────────────────────────────────────────────────────
# RUTAS EN VPC-A
# ────────────────────────────────────────────────────────

# VPC-A → VPC-B (via peering A↔B o TGW)
resource "aws_route" "a_to_b" {
  count                     = 1
  route_table_id            = aws_route_table.private_a.id
  destination_cidr_block    = "10.2.0.0/16"
  vpc_peering_connection_id = local.is_peering ? aws_vpc_peering_connection.a_b[0].id : null
  transit_gateway_id        = local.is_tgw ? aws_ec2_transit_gateway.this[0].id : null
}

# VPC-A → VPC-C (solo en peering-full y tgw; NO en peering-partial)
resource "aws_route" "a_to_c" {
  count                     = local.is_peering_full || local.is_tgw ? 1 : 0
  route_table_id            = aws_route_table.private_a.id
  destination_cidr_block    = "10.3.0.0/16"
  vpc_peering_connection_id = local.is_peering_full ? aws_vpc_peering_connection.a_c[0].id : null
  transit_gateway_id        = local.is_tgw ? aws_ec2_transit_gateway.this[0].id : null
}

# VPC-A → internet (via VPC-B NAT GW): en peering via pcx A↔B, en tgw via TGW
resource "aws_route" "a_to_internet" {
  count                     = 1
  route_table_id            = aws_route_table.private_a.id
  destination_cidr_block    = "0.0.0.0/0"
  vpc_peering_connection_id = local.is_peering ? aws_vpc_peering_connection.a_b[0].id : null
  transit_gateway_id        = local.is_tgw ? aws_ec2_transit_gateway.this[0].id : null
}

# ────────────────────────────────────────────────────────
# RUTAS EN VPC-B
# ────────────────────────────────────────────────────────

# VPC-B → VPC-A
resource "aws_route" "b_to_a" {
  count                     = 1
  route_table_id            = aws_route_table.private_b.id
  destination_cidr_block    = "10.1.0.0/16"
  vpc_peering_connection_id = local.is_peering ? aws_vpc_peering_connection.a_b[0].id : null
  transit_gateway_id        = local.is_tgw ? aws_ec2_transit_gateway.this[0].id : null
}

# VPC-B → VPC-C
resource "aws_route" "b_to_c" {
  count                     = 1
  route_table_id            = aws_route_table.private_b.id
  destination_cidr_block    = "10.3.0.0/16"
  vpc_peering_connection_id = local.is_peering ? aws_vpc_peering_connection.b_c[0].id : null
  transit_gateway_id        = local.is_tgw ? aws_ec2_transit_gateway.this[0].id : null
}

# ────────────────────────────────────────────────────────
# RUTAS EN VPC-C
# ────────────────────────────────────────────────────────

# VPC-C → VPC-B
resource "aws_route" "c_to_b" {
  count                     = 1
  route_table_id            = aws_route_table.private_c.id
  destination_cidr_block    = "10.2.0.0/16"
  vpc_peering_connection_id = local.is_peering ? aws_vpc_peering_connection.b_c[0].id : null
  transit_gateway_id        = local.is_tgw ? aws_ec2_transit_gateway.this[0].id : null
}

# VPC-C → VPC-A (solo en peering-full y tgw)
resource "aws_route" "c_to_a" {
  count                     = local.is_peering_full || local.is_tgw ? 1 : 0
  route_table_id            = aws_route_table.private_c.id
  destination_cidr_block    = "10.1.0.0/16"
  vpc_peering_connection_id = local.is_peering_full ? aws_vpc_peering_connection.a_c[0].id : null
  transit_gateway_id        = local.is_tgw ? aws_ec2_transit_gateway.this[0].id : null
}

# VPC-C → internet (via VPC-B NAT GW)
resource "aws_route" "c_to_internet" {
  count                     = 1
  route_table_id            = aws_route_table.private_c.id
  destination_cidr_block    = "0.0.0.0/0"
  vpc_peering_connection_id = local.is_peering ? aws_vpc_peering_connection.b_c[0].id : null
  transit_gateway_id        = local.is_tgw ? aws_ec2_transit_gateway.this[0].id : null
}
