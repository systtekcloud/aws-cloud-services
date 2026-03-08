# ──── Local Variables ────────────────────────────────────────────────────────────────
locals {
  common_tags = merge(var.tags, {
    ManagedBy = "terraform"
    VpcName   = var.vpc_name
  })
}

# ── VPC ─────────────────────────────────────────────────────────────────────
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = var.vpc_name })
}

# ── Subnets públicas ─────────────────────────────────────────────────────────
resource "aws_subnet" "public" {
  count                   = length(var.public_subnets)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnets[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-public-${count.index + 1}"
    Tier = "public"
  })
}

# ── Subnets privadas ─────────────────────────────────────────────────────────
resource "aws_subnet" "private" {
  count             = length(var.private_subnets)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnets[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-private-${count.index + 1}"
    Tier = "private"
  })
}

# ── Subnets aisladas ─────────────────────────────────────────────────────────
resource "aws_subnet" "isolated" {
  count             = length(var.isolated_subnets)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.isolated_subnets[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(local.common_tags, {
    Name = "${var.vpc_name}-isolated-${count.index + 1}"
    Tier = "isolated"
  })
}

# ── Internet Gateway ─────────────────────────────────────────────────────────
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.common_tags, { Name = "igw-${var.vpc_name}" })
}

# ── NAT Gateway (condicional) ────────────────────────────────────────────────
resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "eip-nat-${var.vpc_name}" })
}

resource "aws_nat_gateway" "this" {
  count         = var.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  tags          = merge(local.common_tags, { Name = "nat-${var.vpc_name}" })
  depends_on    = [aws_internet_gateway.this]
}

# ── Route Tables ─────────────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.common_tags, { Name = "rt-public-${var.vpc_name}" })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.common_tags, { Name = "rt-private-${var.vpc_name}" })
}

resource "aws_route" "private_nat" {
  count                  = var.enable_nat_gateway ? 1 : 0
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table" "isolated" {
  vpc_id = aws_vpc.this.id
  # Sin ruta 0.0.0.0/0 — intencional
  tags = merge(local.common_tags, { Name = "rt-isolated-${var.vpc_name}" })
}

resource "aws_route_table_association" "isolated" {
  count          = length(aws_subnet.isolated)
  subnet_id      = aws_subnet.isolated[count.index].id
  route_table_id = aws_route_table.isolated.id
}

# ── Gateway Endpoint S3 (condicional, gratis) ────────────────────────────────
resource "aws_vpc_endpoint" "s3" {
  count             = var.enable_s3_endpoint ? 1 : 0
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = [
    aws_route_table.private.id,
    aws_route_table.isolated.id,
  ]
  tags = merge(local.common_tags, { Name = "ep-s3-${var.vpc_name}" })
}

data "aws_region" "current" {}

# ── Flow Logs (condicional) ──────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "flow_logs" {
  count             = var.enable_flow_logs ? 1 : 0
  name              = "/vpc/flow-logs/${var.vpc_name}"
  retention_in_days = 7
  tags              = local.common_tags
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0
  name  = "flow-logs-role-${var.vpc_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0
  name  = "flow-logs-cw-policy"
  role  = aws_iam_role.flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup", "logs:CreateLogStream",
        "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_flow_log" "this" {
  count                    = var.enable_flow_logs ? 1 : 0
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  iam_role_arn             = aws_iam_role.flow_logs[0].arn
  log_destination          = aws_cloudwatch_log_group.flow_logs[0].arn
  max_aggregation_interval = 60
  tags                     = merge(local.common_tags, { Name = "flow-logs-${var.vpc_name}" })
}

# ── NACL para subnets aisladas ────────────────────────────────────────────────
# Stateless: necesita reglas explícitas inbound + outbound, incluidos puertos efímeros
resource "aws_network_acl" "isolated" {
  vpc_id     = aws_vpc.this.id
  subnet_ids = aws_subnet.isolated[*].id

  # Inbound: respuestas TCP desde S3 vía Gateway Endpoint (puertos efímeros)
  # NACLs no soportan prefix lists — 0.0.0.0/0 es seguro: rt-isolated no tiene ruta default
  ingress {
    rule_no    = 90
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # Inbound: PostgreSQL desde subnets privadas
  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.private_subnets[0]
    from_port  = 5432
    to_port    = 5432
  }

  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.private_subnets[1]
    from_port  = 5432
    to_port    = 5432
  }

  # Inbound: ICMP desde subnets privadas (ping hacia la DB)
  ingress {
    rule_no    = 120
    protocol   = "icmp"
    action     = "allow"
    cidr_block = var.private_subnets[0]
    from_port  = 0
    to_port    = 0
    icmp_type  = -1
    icmp_code  = -1
  }

  ingress {
    rule_no    = 130
    protocol   = "icmp"
    action     = "allow"
    cidr_block = var.private_subnets[1]
    from_port  = 0
    to_port    = 0
    icmp_type  = -1
    icmp_code  = -1
  }

  # Outbound: HTTPS hacia S3 vía Gateway Endpoint
  egress {
    rule_no    = 90
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  # Outbound: puertos efímeros hacia privadas (respuestas TCP de 5432)
  egress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.private_subnets[0]
    from_port  = 1024
    to_port    = 65535
  }

  egress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.private_subnets[1]
    from_port  = 1024
    to_port    = 65535
  }

  # Outbound: ICMP hacia subnets privadas (echo-reply del ping)
  egress {
    rule_no    = 120
    protocol   = "icmp"
    action     = "allow"
    cidr_block = var.private_subnets[0]
    from_port  = 0
    to_port    = 0
    icmp_type  = -1
    icmp_code  = -1
  }

  egress {
    rule_no    = 130
    protocol   = "icmp"
    action     = "allow"
    cidr_block = var.private_subnets[1]
    from_port  = 0
    to_port    = 0
    icmp_type  = -1
    icmp_code  = -1
  }

  tags = merge(local.common_tags, { Name = "nacl-isolated-${var.vpc_name}" })
}
