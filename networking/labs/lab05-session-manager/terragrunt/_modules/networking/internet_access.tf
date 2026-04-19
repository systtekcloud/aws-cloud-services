# _modules/networking/internet_access.tf
#
# NAT Gateway para modo "internet".
# La EC2 en subnet privada sale a internet via NAT GW,
# y SSM Agent contacta el servicio SSM de AWS por esa ruta.
#
# En modo "endpoints" este fichero no crea nada (count = 0).

resource "aws_eip" "nat" {
  count  = var.ssm_mode == "internet" ? 1 : 0
  domain = "vpc"
  tags   = { Name = "lab05-eip-nat-${var.environment}" }
}

resource "aws_nat_gateway" "this" {
  count         = var.ssm_mode == "internet" ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "lab05-nat-${var.environment}" }
  depends_on    = [aws_internet_gateway.this]
}

# Ruta de salida a internet en la route table privada
resource "aws_route" "private_internet" {
  count                  = var.ssm_mode == "internet" ? 1 : 0
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}
