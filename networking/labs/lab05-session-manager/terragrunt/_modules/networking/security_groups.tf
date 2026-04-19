# _modules/networking/security_groups.tf
#
# Dos Security Groups:
#
# 1. SG de la EC2:
#    - Zero ingress (sin puerto 22, sin nada)
#    - Egress completo (para SSM Agent y las pruebas de curl)
#    Este SG demuestra que no se necesita SSH ni Bastion Host.
#
# 2. SG de los Interface Endpoints (solo en modo endpoints):
#    - Ingress 443 desde la subnet privada
#    - Sin este SG, los endpoints no aceptan conexiones del SSM Agent
#    Este es el error más común al configurar endpoints SSM.

resource "aws_security_group" "ec2" {
  name        = "lab05-sg-ec2-${var.environment}"
  description = "EC2 sin ingress. Acceso exclusivo via SSM. Sin puerto 22."
  vpc_id      = aws_vpc.this.id

  # Zero ingress — demostramos que no necesitamos SSH ni reglas de entrada
  # SSM Session Manager no requiere ningún puerto de entrada en el SG de la EC2

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Egress completo - necesario para SSM Agent (internet o endpoints)"
  }

  tags = { Name = "lab05-sg-ec2-${var.environment}" }
}

# SG para los Interface Endpoints — solo en modo endpoints
# Los endpoints crean ENIs en la subnet privada. Esas ENIs necesitan
# aceptar HTTPS (443) desde la EC2 para que SSM Agent pueda conectarse.
resource "aws_security_group" "endpoints" {
  count       = var.ssm_mode == "endpoints" ? 1 : 0
  name        = "lab05-sg-endpoints-${var.environment}"
  description = "Interface Endpoints SSM: ingress 443 desde subnet privada"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS desde subnet privada — SSM Agent conecta a los endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_subnet.private.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Egress completo"
  }

  tags = { Name = "lab05-sg-endpoints-${var.environment}" }
}
