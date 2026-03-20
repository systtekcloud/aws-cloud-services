# _modules/networking/peering.tf
#
# VPC Peerings con lógica condicional según connectivity_mode:
#
#   peering-partial → A↔B + B↔C (2 peerings)
#   peering-full    → A↔B + B↔C + A↔C (3 peerings = full mesh para 3 VPCs)
#   tgw             → ningún peering (0 peerings, usa TGW)
#
# VPC Peering es GRATUITO. Solo se paga el data transfer entre VPCs ($0.01/GB).
# El problema no es el coste, es la gestión: N*(N-1)/2 peerings para full mesh.
# Con 10 VPCs serían 45 peerings. Con 100 VPCs serían 4950.

locals {
  # true si estamos en cualquier modo peering
  peering_mode = startswith(var.connectivity_mode, "peering")
}

# Peering A↔B — activo en peering-partial y peering-full
resource "aws_vpc_peering_connection" "a_b" {
  count       = local.peering_mode ? 1 : 0
  vpc_id      = aws_vpc.a.id
  peer_vpc_id = aws_vpc.b.id
  auto_accept = true
  tags        = { Name = "lab04-pcx-a-b-${var.environment}" }
}

# Peering B↔C — activo en peering-partial y peering-full
resource "aws_vpc_peering_connection" "b_c" {
  count       = local.peering_mode ? 1 : 0
  vpc_id      = aws_vpc.b.id
  peer_vpc_id = aws_vpc.c.id
  auto_accept = true
  tags        = { Name = "lab04-pcx-b-c-${var.environment}" }
}

# Peering A↔C — SOLO en peering-full
# Este es el peering que "soluciona" la no-transitividad,
# pero ilustra el problema de escala del full mesh.
resource "aws_vpc_peering_connection" "a_c" {
  count       = var.connectivity_mode == "peering-full" ? 1 : 0
  vpc_id      = aws_vpc.a.id
  peer_vpc_id = aws_vpc.c.id
  auto_accept = true
  tags        = { Name = "lab04-pcx-a-c-${var.environment}" }
}
