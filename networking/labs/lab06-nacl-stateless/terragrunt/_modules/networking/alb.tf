# _modules/networking/alb.tf
#
# ALB en subnets publicas -> target group -> EC2 en subnet privada
# HTTP (puerto 80) — sin HTTPS para simplificar el lab
# El ALB necesita minimo 2 AZs para poder crearse

resource "aws_lb" "this" {
  name               = "lab06-alb-${var.environment}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public.id, aws_subnet.public_b.id]

  tags = { Name = "lab06-alb-${var.environment}" }
}

resource "aws_lb_target_group" "this" {
  name     = "lab06-tg-${var.environment}"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.this.id

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = { Name = "lab06-tg-${var.environment}" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

resource "aws_lb_target_group_attachment" "ec2" {
  target_group_arn = aws_lb_target_group.this.arn
  target_id        = aws_instance.this.id
  port             = 80
}
