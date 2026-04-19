# _modules/networking/ec2.tf
#
# EC2 t3.micro en subnet privada. Amazon Linux 2023 con SSM Agent preinstalado.
# IAM role con AmazonSSMManagedInstanceCore — mínimo necesario para SSM.
# Sin IP pública, sin SSH key pair.

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

resource "aws_iam_role" "ec2_ssm" {
  name = "lab05-ec2-ssm-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Política gestionada de AWS — mínimo necesario para SSM Session Manager
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "lab05-ec2-ssm-profile-${var.environment}"
  role = aws_iam_role.ec2_ssm.name
}

resource "aws_instance" "this" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private.id
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name
  vpc_security_group_ids = [aws_security_group.ec2.id]

  # Sin key_name — no necesitamos SSH key pair
  # Sin associate_public_ip_address — subnet privada, no tiene IP pública

  tags = { Name = "lab05-ec2-${var.environment}" }
}
