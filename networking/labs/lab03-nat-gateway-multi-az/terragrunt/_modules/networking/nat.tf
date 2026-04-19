# _modules/networking/nat.tf
#
# La variable nat_ha controla cuántos NAT Gateways se crean:
#   nat_ha = false → count = 1 → solo NAT GW en AZ-a
#   nat_ha = true  → count = 2 → NAT GW en AZ-a Y AZ-b
#
# Cada NAT GW necesita una Elastic IP y debe vivir en una subnet PÚBLICA.
# El NAT GW es un recurso ZONAL — si su AZ falla, él falla con ella.

resource "aws_eip" "nat" {
  count  = var.nat_ha ? 2 : 1
  domain = "vpc"

  tags = {
    Name = "lab03-eip-nat-${count.index == 0 ? "a" : "b"}-${var.environment}"
  }
}

resource "aws_nat_gateway" "this" {
  count         = var.nat_ha ? 2 : 1
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id  # nat[0] en public-a, nat[1] en public-b

  tags = {
    Name = "lab03-nat-${count.index == 0 ? "a" : "b"}-${var.environment}"
  }

  depends_on = [aws_internet_gateway.this]
}
