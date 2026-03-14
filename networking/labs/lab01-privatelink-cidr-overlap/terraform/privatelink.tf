# =============================================================================
# privatelink.tf — VPC Endpoint Service (VPC-B) + Interface Endpoint (VPC-A)
#
# ARQUITECTURA DE PRIVATELINK:
#
#   VPC-A (Consumer)              AWS PrivateLink              VPC-B (Provider)
#   ─────────────────────         ────────────────             ─────────────────────
#   Consumer EC2                                               Provider EC2
#     │                                                          │
#     │ curl endpoint-dns:8080                                   │
#     ▼                                                          ▼
#   Interface Endpoint ENI  ◄──── [tunnel privado] ────►   NLB → Target Group
#   (IP en subnet VPC-A)                                   (IP en subnet VPC-B)
#
# El consumidor solo conoce la IP de la ENI del endpoint (en su propia VPC-A).
# Nunca hay enrutamiento IP directo entre VPC-A y VPC-B → los CIDRs solapados
# no importan.
# =============================================================================

# ---------------------------------------------------------------------------
# VPC Endpoint Service — en VPC-B, expone el NLB como un servicio consumible
# ---------------------------------------------------------------------------
resource "aws_vpc_endpoint_service" "provider" {
  # El NLB es el único backend soportado para Endpoint Services
  network_load_balancer_arns = [aws_lb.provider.arn]

  # acceptance_required = false: auto-acepta cualquier conexión de endpoint
  # En producción usar true + aws_vpc_endpoint_connection_accepter para control
  acceptance_required = false

  tags = { Name = "${var.prefix}-endpoint-service" }
}

# ---------------------------------------------------------------------------
# VPC Interface Endpoint — en VPC-A, crea una ENI que representa el servicio
#
# La ENI tiene una IP privada en la subnet de VPC-A (10.0.1.x).
# El consumer EC2 conecta a esta IP (o al DNS del endpoint) — nunca ve las IPs de VPC-B.
# ---------------------------------------------------------------------------
resource "aws_vpc_endpoint" "consumer" {
  vpc_id             = aws_vpc.a.id
  service_name       = aws_vpc_endpoint_service.provider.service_name
  vpc_endpoint_type  = "Interface"
  subnet_ids         = [aws_subnet.a.id]
  security_group_ids = [aws_security_group.endpoint.id]

  # private_dns_enabled solo aplica para servicios AWS (s3, ec2, etc.)
  # Para servicios privados custom (Endpoint Services) no aplica
  private_dns_enabled = false

  tags = { Name = "${var.prefix}-interface-endpoint" }
}

# ---------------------------------------------------------------------------
# Nota sobre DNS del Interface Endpoint:
#
# El endpoint genera un DNS name del tipo:
#   vpce-XXXX.svc.YYYY.eu-west-1.vpce.amazonaws.com
#
# Este hostname resuelve a la IP privada de la ENI en la subnet de VPC-A.
# El consumer EC2 usa este hostname para conectarse:
#   curl http://vpce-XXXX.svc.YYYY.eu-west-1.vpce.amazonaws.com:8080/
#
# Ver el output "endpoint_dns_name" para obtener el hostname exacto.
# ---------------------------------------------------------------------------
