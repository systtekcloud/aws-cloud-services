# _modules/networking/tgw.tf
#
# Transit Gateway — activo solo en modo "tgw".
#
# TGW actúa como router centralizado (hub). Cada VPC se conecta
# al TGW con un "attachment". El TGW tiene su propia route table
# que propaga automáticamente las rutas de todos los attachments.
#
# Coste TGW:
#   - $0.05/h por attachment × 3 attachments = $0.15/h
#   - + $0.02/GB de datos procesados
#
# A diferencia del peering (gratuito), TGW tiene coste por attachment.
# La ventaja es que N VPCs = N attachments (no N*(N-1)/2 peerings).

resource "aws_ec2_transit_gateway" "this" {
  count                           = var.connectivity_mode == "tgw" ? 1 : 0
  description                     = "Lab04 TGW — hub para VPC-A, VPC-B, VPC-C"
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"
  tags                            = { Name = "lab04-tgw-${var.environment}" }
}

# Attachment de VPC-A al TGW
resource "aws_ec2_transit_gateway_vpc_attachment" "a" {
  count              = var.connectivity_mode == "tgw" ? 1 : 0
  transit_gateway_id = aws_ec2_transit_gateway.this[0].id
  vpc_id             = aws_vpc.a.id
  subnet_ids         = [aws_subnet.private_a.id]
  tags               = { Name = "lab04-tgw-attach-a-${var.environment}" }
}

# Attachment de VPC-B al TGW
resource "aws_ec2_transit_gateway_vpc_attachment" "b" {
  count              = var.connectivity_mode == "tgw" ? 1 : 0
  transit_gateway_id = aws_ec2_transit_gateway.this[0].id
  vpc_id             = aws_vpc.b.id
  subnet_ids         = [aws_subnet.private_b.id]
  tags               = { Name = "lab04-tgw-attach-b-${var.environment}" }
}

# Attachment de VPC-C al TGW
resource "aws_ec2_transit_gateway_vpc_attachment" "c" {
  count              = var.connectivity_mode == "tgw" ? 1 : 0
  transit_gateway_id = aws_ec2_transit_gateway.this[0].id
  vpc_id             = aws_vpc.c.id
  subnet_ids         = [aws_subnet.private_c.id]
  tags               = { Name = "lab04-tgw-attach-c-${var.environment}" }
}
