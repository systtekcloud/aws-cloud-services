# _modules/networking/nacl.tf
#
# NACL asociado a la subnet-private donde vive la EC2.
# El NACL es stateless: cada paquete se evalua independientemente.
# La regla 200 outbound (efimeros) es la clave del lab:
# el validate.sh la elimina y restaura para demostrar el comportamiento.
#
# Reglas de la subnet-publica: usamos el NACL por defecto de la VPC (allow all).
# Solo restringimos la subnet privada para focalizar el aprendizaje.

resource "aws_network_acl" "private" {
  vpc_id     = aws_vpc.this.id
  subnet_ids = [aws_subnet.private.id]
  tags       = { Name = "lab06-nacl-private-${var.environment}" }
}

# Inbound: permitir HTTP (80) desde cualquier IP (el ALB envia trafico desde su IP privada)
resource "aws_network_acl_rule" "inbound_http" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 100
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 80
  to_port        = 80
}

# Inbound: denegar todo lo demas
resource "aws_network_acl_rule" "inbound_deny_all" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 32766
  egress         = false
  protocol       = "-1"
  rule_action    = "deny"
  cidr_block     = "0.0.0.0/0"
  from_port      = 0
  to_port        = 0
}

# Outbound: permitir puertos efimeros (1024-65535) para las respuestas HTTP
# ESTA ES LA REGLA CLAVE DEL LAB.
# Sin ella, nginx recibe el request pero la respuesta TCP no puede salir.
# Los navegadores y curl usan puertos efimeros (1024-65535) como puerto origen.
# El servidor responde a ese puerto — si NACL outbound no lo permite -> timeout.
resource "aws_network_acl_rule" "outbound_ephemeral" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 200
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

# Outbound: denegar todo lo demas
resource "aws_network_acl_rule" "outbound_deny_all" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 32766
  egress         = true
  protocol       = "-1"
  rule_action    = "deny"
  cidr_block     = "0.0.0.0/0"
  from_port      = 0
  to_port        = 0
}
