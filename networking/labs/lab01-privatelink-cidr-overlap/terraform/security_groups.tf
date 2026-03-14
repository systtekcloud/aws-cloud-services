# =============================================================================
# security_groups.tf — Security Groups para consumer, provider y endpoint
# =============================================================================

# ---------------------------------------------------------------------------
# SG Consumer (VPC-A) — EC2 que consume el servicio via PrivateLink
# ---------------------------------------------------------------------------
resource "aws_security_group" "consumer" {
  name        = "${var.prefix}-sg-consumer"
  description = "Consumer EC2: egress HTTPS para SSM + egress al endpoint"
  vpc_id      = aws_vpc.a.id

  # Sin reglas de ingress: el consumer no necesita recibir conexiones
  # SSM Session Manager conecta de salida (egress), no de entrada

  egress {
    description = "HTTPS para SSM agent (contacta endpoints SSM de AWS via internet)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description     = "HTTP hacia el Interface Endpoint (puerto del servicio VPC-B)"
    from_port       = var.http_port
    to_port         = var.http_port
    protocol        = "tcp"
    security_groups = [aws_security_group.endpoint.id]
  }

  tags = { Name = "${var.prefix}-sg-consumer" }
}

# ---------------------------------------------------------------------------
# SG Interface Endpoint (VPC-A) — ENI del VPC Interface Endpoint
# El endpoint actúa como proxy: recibe del consumer, reenvía al NLB en VPC-B
# ---------------------------------------------------------------------------
resource "aws_security_group" "endpoint" {
  name        = "${var.prefix}-sg-endpoint"
  description = "Interface Endpoint: acepta del consumer, permite respuesta"
  vpc_id      = aws_vpc.a.id

  ingress {
    description     = "Tráfico HTTP desde el consumer EC2"
    from_port       = var.http_port
    to_port         = var.http_port
    protocol        = "tcp"
    security_groups = [aws_security_group.consumer.id]
  }

  egress {
    description = "Respuestas de vuelta al consumer"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_a_subnet_cidr]
  }

  tags = { Name = "${var.prefix}-sg-endpoint" }
}

# ---------------------------------------------------------------------------
# SG Provider (VPC-B) — EC2 que sirve el HTTP service
# Solo acepta tráfico del NLB (NLBs preservan la IP fuente, pero en VPCs
# privadas el tráfico llega desde la IP del NLB o del CIDR de la subnet NLB)
# ---------------------------------------------------------------------------
resource "aws_security_group" "provider" {
  name        = "${var.prefix}-sg-provider"
  description = "Provider EC2: acepta HTTP desde NLB en VPC-B"
  vpc_id      = aws_vpc.b.id

  ingress {
    description = "HTTP desde NLB (NLB preserva IP fuente, pero puede ser CIDR VPC-B)"
    from_port   = var.http_port
    to_port     = var.http_port
    protocol    = "tcp"
    # NLBs no tienen SG propio — el tráfico llega con la IP del cliente o del NLB
    # En labs, usar el CIDR de la VPC es aceptable
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Respuestas HTTP al cliente"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-sg-provider" }
}
