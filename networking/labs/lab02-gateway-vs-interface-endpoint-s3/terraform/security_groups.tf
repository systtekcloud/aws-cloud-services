# =============================================================================
# security_groups.tf — Sin puerto 22, acceso solo via SSM
#
# No abrimos SSH porque usamos AWS Systems Manager Session Manager.
# SSM funciona porque las EC2 tienen IAM Instance Profile con AmazonSSMManagedInstanceCore
# y alcanzan los endpoints SSM via NAT Gateway (ambas subnets tienen ruta 0.0.0.0/0 → NAT).
# =============================================================================

resource "aws_security_group" "ec2" {
  name        = "${var.prefix}-sg-ec2"
  description = "SG para EC2 de lab — sin SSH, acceso via SSM"
  vpc_id      = aws_vpc.main.id

  # Sin reglas de ingress — las EC2 no necesitan recibir tráfico entrante
  # SSM Session Manager inicia la conexión desde AWS (outbound desde EC2)

  egress {
    description = "All outbound traffic allowed - required for SSM and S3"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-sg-ec2" }
}
