# _modules/networking/routes.tf
#
# Cada subnet privada tiene su propia route table.
# Esta es la parte crítica del lab:
#
#   nat_ha = false:
#     private-a → nat-a (correcto)
#     private-b → nat-a (SPOF: si AZ-a falla, private-b pierde internet)
#
#   nat_ha = true:
#     private-a → nat-a (correcto)
#     private-b → nat-b (HA: si AZ-a falla, private-b sigue funcionando)

# Route table para subnet-private-a (siempre apunta a nat-a)
resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "lab03-rt-private-a-${var.environment}"
  }
}

resource "aws_route" "private_a_internet" {
  route_table_id         = aws_route_table.private_a.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private[0].id
  route_table_id = aws_route_table.private_a.id
}

# Route table para subnet-private-b
# → nat-a si nat_ha=false (SPOF)
# → nat-b si nat_ha=true  (HA)
resource "aws_route_table" "private_b" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "lab03-rt-private-b-${var.environment}"
  }
}

resource "aws_route" "private_b_internet" {
  route_table_id         = aws_route_table.private_b.id
  destination_cidr_block = "0.0.0.0/0"
  # Aquí está la diferencia: con HA usamos el NAT de AZ-b, sin HA usamos el de AZ-a
  nat_gateway_id         = var.nat_ha ? aws_nat_gateway.this[1].id : aws_nat_gateway.this[0].id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private[1].id
  route_table_id = aws_route_table.private_b.id
}
