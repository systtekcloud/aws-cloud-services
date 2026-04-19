# _modules/networking/ec2.tf
#
# EC2 t3.micro en subnet privada. Nginx instalado via user_data.
# IAM role con AmazonSSMManagedInstanceCore para acceso SSM.
# Sin IP publica, sin SSH key pair.
# NAT GW incluido aqui para que SSM Agent se registre (subnet privada sin endpoints).

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "lab06-eip-nat-${var.environment}" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "lab06-nat-${var.environment}" }
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route" "private_internet" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

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
  name = "lab06-ec2-ssm-role-${var.environment}"
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
  name = "lab06-ec2-ssm-profile-${var.environment}"
  role = aws_iam_role.ec2_ssm.name
}

resource "aws_instance" "this" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private.id
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name
  vpc_security_group_ids = [aws_security_group.ec2.id]

  user_data = <<-EOF
    #!/bin/bash
    dnf install -y nginx
    systemctl enable nginx
    systemctl start nginx
    echo "<h1>Lab 06 - NACL Stateless Demo</h1><p>Instance: $(hostname)</p>" > /usr/share/nginx/html/index.html
  EOF

  tags = { Name = "lab06-ec2-${var.environment}" }
}
