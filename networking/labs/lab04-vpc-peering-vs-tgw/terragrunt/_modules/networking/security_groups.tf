# _modules/networking/security_groups.tf
#
# Un SG por VPC. Reglas:
# - Ingress ICMP desde los CIDRs de las otras VPCs (para el ping de validación)
# - Egress completo (para SSM Agent y curl de validación)
# Sin puerto 22 — acceso exclusivo via SSM Session Manager.

resource "aws_security_group" "ec2_a" {
  name        = "lab04-sg-ec2-a-${var.environment}"
  description = "EC2-A: ICMP desde VPC-B y VPC-C, egress completo"
  vpc_id      = aws_vpc.a.id

  ingress {
    description = "ICMP desde VPC-B"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["10.2.0.0/16"]
  }

  ingress {
    description = "ICMP desde VPC-C"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["10.3.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = { Name = "lab04-sg-ec2-a-${var.environment}" }
}

resource "aws_security_group" "ec2_b" {
  name        = "lab04-sg-ec2-b-${var.environment}"
  description = "EC2-B: ICMP desde VPC-A y VPC-C, egress completo"
  vpc_id      = aws_vpc.b.id

  ingress {
    description = "ICMP desde VPC-A"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["10.1.0.0/16"]
  }

  ingress {
    description = "ICMP desde VPC-C"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["10.3.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = { Name = "lab04-sg-ec2-b-${var.environment}" }
}

resource "aws_security_group" "ec2_c" {
  name        = "lab04-sg-ec2-c-${var.environment}"
  description = "EC2-C: ICMP desde VPC-A y VPC-B, egress completo"
  vpc_id      = aws_vpc.c.id

  ingress {
    description = "ICMP desde VPC-A"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["10.1.0.0/16"]
  }

  ingress {
    description = "ICMP desde VPC-B"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["10.2.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = { Name = "lab04-sg-ec2-c-${var.environment}" }
}
