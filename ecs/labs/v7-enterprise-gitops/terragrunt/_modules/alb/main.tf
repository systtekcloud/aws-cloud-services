# ── Módulo: ALB — ShopAPI ─────────────────────────────────────────────────────
# Crea el Application Load Balancer público con:
#   - Security Group (puerto 80 y 443 desde internet)
#   - Target Group (IP mode para Fargate awsvpc)
#   - Listener HTTP en el puerto 80

# ── Security Group del ALB ────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "shopapi-alb-sg-${var.environment}"
  description = "Permite tráfico HTTP/HTTPS entrante al ALB desde internet"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP desde internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS desde internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Todo el tráfico de salida"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "shopapi-alb-sg-${var.environment}"
  }
}

# ── Application Load Balancer ─────────────────────────────────────────────────

resource "aws_lb" "main" {
  name               = "shopapi-alb-${var.environment}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = var.deletion_protection

  dynamic "access_logs" {
    for_each = var.access_logs_enabled ? [1] : []
    content {
      bucket  = var.access_logs_bucket
      prefix  = var.access_logs_prefix
      enabled = true
    }
  }

  tags = {
    Name = "shopapi-alb-${var.environment}"
  }
}

# ── Target Group ──────────────────────────────────────────────────────────────
# target_type = "ip" es obligatorio para Fargate con awsvpc network mode.
# El ALB enruta al IP de la task directamente, sin pasar por el host.

resource "aws_lb_target_group" "api" {
  name                 = "shopapi-api-tg-${var.environment}"
  port                 = 8080
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  target_type          = "ip"
  deregistration_delay = var.deregistration_delay

  health_check {
    enabled             = true
    path                = var.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    interval            = var.health_check_interval
    timeout             = var.health_check_timeout
    healthy_threshold   = var.healthy_threshold
    unhealthy_threshold = var.unhealthy_threshold
    matcher             = "200"
  }

  tags = {
    Name = "shopapi-api-tg-${var.environment}"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Listener HTTP ─────────────────────────────────────────────────────────────
# En producción real: usar HTTPS con certificado ACM.
# Para el lab se usa HTTP por simplicidad.

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  tags = {
    Name = "shopapi-http-listener-${var.environment}"
  }
}
