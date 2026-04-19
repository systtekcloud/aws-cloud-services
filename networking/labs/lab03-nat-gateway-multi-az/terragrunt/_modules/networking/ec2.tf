# _modules/networking/ec2.tf

# Amazon Linux 2023 — última versión disponible en la región
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# IAM role para las EC2 — necesario para SSM Session Manager
# SSM Agent necesita poder registrarse en el servicio SSM de AWS
resource "aws_iam_role" "ec2_ssm" {
  name = "lab03-ec2-ssm-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Política gestionada de AWS para SSM — permite al agente conectarse al servicio
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "lab03-ec2-ssm-profile-${var.environment}"
  role = aws_iam_role.ec2_ssm.name
}

# EC2-A en subnet-private-a (AZ-a)
resource "aws_instance" "ec2_a" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private[0].id
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name
  vpc_security_group_ids = [aws_security_group.ec2.id]

  # SSM Agent viene preinstalado en Amazon Linux 2023
  # Solo necesitamos que la instancia tenga IAM role + acceso a internet (via NAT)
  # para registrarse en el servicio SSM

  tags = {
    Name = "lab03-ec2-a-${var.environment}"
    AZ   = "az-a"
  }
}

# EC2-B en subnet-private-b (AZ-b)
resource "aws_instance" "ec2_b" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private[1].id
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name
  vpc_security_group_ids = [aws_security_group.ec2.id]

  tags = {
    Name = "lab03-ec2-b-${var.environment}"
    AZ   = "az-b"
  }
}
