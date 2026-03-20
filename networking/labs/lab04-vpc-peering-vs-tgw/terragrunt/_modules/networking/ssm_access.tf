# _modules/networking/ssm_access.tf
#
# NAT Gateway en VPC-B para que SSM Agent de las 3 EC2 pueda
# registrarse en el servicio SSM de AWS (requiere acceso a internet).
#
# EC2-B usa el NAT directamente (subnet privada en VPC-B).
# EC2-A y EC2-C enrutan su tráfico 0.0.0.0/0 hacia VPC-B via peering o TGW,
# y desde VPC-B salen por el NAT GW.
#
# Esto mantiene el coste bajo (un solo NAT GW) y no interfiere con
# el concepto a demostrar (conectividad A↔C).

resource "aws_eip" "nat_b" {
  domain = "vpc"
  tags   = { Name = "lab04-eip-nat-b-${var.environment}" }
}

resource "aws_nat_gateway" "b" {
  allocation_id = aws_eip.nat_b.id
  subnet_id     = aws_subnet.public_b.id
  tags          = { Name = "lab04-nat-b-${var.environment}" }
  depends_on    = [aws_internet_gateway.b]
}

# Route de salida a internet en VPC-B (para EC2-B y tráfico de A y C en modo peering)
resource "aws_route" "private_b_internet" {
  route_table_id         = aws_route_table.private_b.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.b.id
}
