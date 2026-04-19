# _modules/networking/security_groups.tf
#
# SG para las EC2 del lab. Solo permite tráfico de salida (egress).
# Sin reglas de ingreso en puerto 22 — acceso via SSM Session Manager únicamente.
# Esto es best practice: zero inbound, SSM gestiona el acceso.

resource "aws_security_group" "ec2" {
  name        = "lab03-ec2-sg-${var.environment}"
  description = "SG para EC2 del lab03. Acceso via SSM, sin puerto 22."
  vpc_id      = aws_vpc.this.id

  # Egress completo — necesario para curl, SSM agent y descarga de paquetes
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "lab03-ec2-sg-${var.environment}"
  }
}
