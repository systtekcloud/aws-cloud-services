# _modules/networking/security_groups.tf
#
# SG ALB: ingress 80 desde internet, egress hacia EC2 en subnet privada
# SG EC2: ingress 80 SOLO desde el ALB (via SG reference), zero ingress SSH

# SG para el ALB — acepta trafico HTTP desde internet
resource "aws_security_group" "alb" {
  name        = "lab06-sg-alb-${var.environment}"
  description = "ALB: acepta HTTP desde internet"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP desde internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "lab06-sg-alb-${var.environment}" }
}

# SG para la EC2 — acepta HTTP solo desde el ALB (referencia al SG, no CIDR)
# NOTA: el SG es stateful — si la EC2 puede RECIBIR en 80, la RESPUESTA sale automaticamente.
# Esto contrasta con el NACL (stateless) donde necesitamos la regla de efimeros explicitamente.
resource "aws_security_group" "ec2" {
  name        = "lab06-sg-ec2-${var.environment}"
  description = "EC2: acepta HTTP solo desde el ALB. Sin puerto 22."
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "HTTP desde el ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "lab06-sg-ec2-${var.environment}" }
}
