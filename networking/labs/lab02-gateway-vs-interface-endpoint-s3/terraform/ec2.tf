# =============================================================================
# ec2.tf — Dos instancias EC2 para comparar rutas de tráfico S3
#
# EC2-A (subnet-gw-private): su tráfico S3 usa Gateway Endpoint
# EC2-B (subnet-nat-private): su tráfico S3 pasa por NAT Gateway
#
# Ambas usan SSM Session Manager para acceso shell sin SSH.
# Ambas tienen IAM role con permisos S3 para leer/escribir el bucket de test.
# =============================================================================

# ---------------------------------------------------------------------------
# IAM Role para EC2 — permisos SSM + S3
# ---------------------------------------------------------------------------
resource "aws_iam_role" "ec2" {
  name = "${var.prefix}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.prefix}-ec2-role" }
}

# AmazonSSMManagedInstanceCore — permite SSM Session Manager
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Política inline S3 — permisos solo para el bucket de test
resource "aws_iam_role_policy" "s3_test" {
  name = "${var.prefix}-s3-test-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.test.arn,
          "${aws_s3_bucket.test.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.prefix}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ---------------------------------------------------------------------------
# AMI más reciente de Amazon Linux 2023
# ---------------------------------------------------------------------------
data "aws_ami" "al2023" {
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

# ---------------------------------------------------------------------------
# EC2-A — subnet-gw-private (CON Gateway Endpoint)
# Su tráfico S3 NO pasará por NAT Gateway
# ---------------------------------------------------------------------------
resource "aws_instance" "ec2_gw" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.gw_private.id
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  vpc_security_group_ids = [aws_security_group.ec2.id]

  # SSM Agent viene preinstalado en AL2023
  user_data = base64encode(<<-EOF
    #!/bin/bash
    # Etiquetar la instancia para identificarla en los logs
    export AWS_DEFAULT_REGION=${var.aws_region}
    echo "EC2-A: subnet con Gateway Endpoint S3" > /etc/lab-identity
  EOF
  )

  tags = { Name = "${var.prefix}-ec2-gw" }
}

# ---------------------------------------------------------------------------
# EC2-B — subnet-nat-private (SIN Gateway Endpoint)
# Su tráfico S3 PASARÁ por NAT Gateway
# ---------------------------------------------------------------------------
resource "aws_instance" "ec2_nat" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.nat_private.id
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  vpc_security_group_ids = [aws_security_group.ec2.id]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    export AWS_DEFAULT_REGION=${var.aws_region}
    echo "EC2-B: subnet sin Gateway Endpoint (solo NAT GW)" > /etc/lab-identity
  EOF
  )

  tags = { Name = "${var.prefix}-ec2-nat" }
}
