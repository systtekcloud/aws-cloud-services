# _modules/networking/ec2.tf
#
# Una EC2 t3.micro por VPC. Amazon Linux 2023 (SSM Agent preinstalado).
# IAM role con AmazonSSMManagedInstanceCore para SSM Session Manager.
# Sin SSH, sin bastión — acceso exclusivo via SSM.

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

# IAM role compartido por las 3 EC2
resource "aws_iam_role" "ec2_ssm" {
  name = "lab04-ec2-ssm-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "lab04-ec2-ssm-profile-${var.environment}"
  role = aws_iam_role.ec2_ssm.name
}

resource "aws_instance" "ec2_a" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private_a.id
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name
  vpc_security_group_ids = [aws_security_group.ec2_a.id]
  tags                   = { Name = "lab04-ec2-a-${var.environment}" }
}

resource "aws_instance" "ec2_b" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private_b.id
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name
  vpc_security_group_ids = [aws_security_group.ec2_b.id]
  tags                   = { Name = "lab04-ec2-b-${var.environment}" }
}

resource "aws_instance" "ec2_c" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private_c.id
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name
  vpc_security_group_ids = [aws_security_group.ec2_c.id]
  tags                   = { Name = "lab04-ec2-c-${var.environment}" }
}
