# =============================================================================
# nlb.tf — Network Load Balancer en VPC-B (requerido por PrivateLink)
#
# POR QUÉ NLB y no ALB:
#   AWS PrivateLink (VPC Endpoint Service) solo soporta Network Load Balancers
#   como backend. Un ALB no puede ser el backend de un Endpoint Service.
#
# NLB interno (no internet-facing):
#   El NLB solo necesita ser accesible desde el Interface Endpoint en VPC-A.
#   No necesita IP pública ni acceso desde internet.
# =============================================================================

# ---------------------------------------------------------------------------
# Network Load Balancer — interno en VPC-B
# ---------------------------------------------------------------------------
resource "aws_lb" "provider" {
  name               = "${var.prefix}-nlb-provider"
  internal           = true  # No internet-facing — solo accesible via PrivateLink
  load_balancer_type = "network"
  subnets            = [aws_subnet.b.id]

  # Para un lab, la deletion protection está deshabilitada para poder hacer cleanup fácil
  enable_deletion_protection = false

  tags = { Name = "${var.prefix}-nlb-provider" }
}

# ---------------------------------------------------------------------------
# Target Group — apunta al provider EC2 en el puerto HTTP
# Protocolo TCP porque el NLB opera en capa 4 (no inspecciona HTTP)
# ---------------------------------------------------------------------------
resource "aws_lb_target_group" "provider" {
  name        = "${var.prefix}-tg-provider"
  port        = var.http_port
  protocol    = "TCP" # NLB usa TCP/UDP/TLS — no HTTP (eso sería ALB)
  vpc_id      = aws_vpc.b.id
  target_type = "instance"

  health_check {
    enabled             = true
    protocol            = "TCP"    # Health check TCP: si el puerto responde → healthy
    port                = "traffic-port"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = { Name = "${var.prefix}-tg-provider" }
}

# ---------------------------------------------------------------------------
# Listener — NLB escucha en el puerto HTTP y reenvía al target group
# ---------------------------------------------------------------------------
resource "aws_lb_listener" "provider" {
  load_balancer_arn = aws_lb.provider.arn
  port              = var.http_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.provider.arn
  }
}

# ---------------------------------------------------------------------------
# Target Group Attachment — registrar el provider EC2 en el target group
# ---------------------------------------------------------------------------
resource "aws_lb_target_group_attachment" "provider" {
  target_group_arn = aws_lb_target_group.provider.arn
  target_id        = aws_instance.provider.id
  port             = var.http_port
}
