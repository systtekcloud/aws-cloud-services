# ── Módulo: VPC — ShopAPI ─────────────────────────────────────────────────────
# Crea la red base para el entorno: VPC, subnets públicas y privadas,
# Internet Gateway, NAT Gateway(s) y tablas de rutas.
#
# Subnets por AZ:
#   Públicas:  10.x.0.0/24, 10.x.1.0/24, 10.x.2.0/24  (índice 0,1,2)
#   Privadas:  10.x.10.0/24, 10.x.11.0/24, 10.x.12.0/24 (índice 10,11,12)

locals {
  nat_count = var.single_nat_gateway ? 1 : length(var.availability_zones)
  az_count  = length(var.availability_zones)
}

# ── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "shopapi-vpc-${var.environment}"
  }
}

# ── Subnets públicas (una por AZ) ─────────────────────────────────────────────

resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "shopapi-public-${var.availability_zones[count.index]}-${var.environment}"
    Tier = "public"
  }
}

# ── Subnets privadas (una por AZ) ─────────────────────────────────────────────

resource "aws_subnet" "private" {
  count = local.az_count

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "shopapi-private-${var.availability_zones[count.index]}-${var.environment}"
    Tier = "private"
  }
}

# ── Internet Gateway (para subnets públicas) ──────────────────────────────────

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "shopapi-igw-${var.environment}"
  }
}

# ── Elastic IPs para los NAT Gateways ─────────────────────────────────────────
# single_nat_gateway=true  → 1 EIP (dev/staging: más barato)
# single_nat_gateway=false → 1 EIP por AZ (prod: más resiliente)

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"

  tags = {
    Name = "shopapi-nat-eip-${count.index}-${var.environment}"
  }

  depends_on = [aws_internet_gateway.main]
}

# ── NAT Gateways ──────────────────────────────────────────────────────────────
# Se sitúan en subnets públicas para permitir tráfico saliente desde las privadas.

resource "aws_nat_gateway" "main" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "shopapi-nat-${count.index}-${var.environment}"
  }

  depends_on = [aws_internet_gateway.main]
}

# ── Tabla de rutas pública ─────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "shopapi-public-rt-${var.environment}"
  }
}

resource "aws_route_table_association" "public" {
  count = local.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── Tablas de rutas privadas ───────────────────────────────────────────────────
# Con single_nat_gateway=true: una sola RT privada → NAT único
# Con single_nat_gateway=false: una RT privada por AZ → NAT de la misma AZ

resource "aws_route_table" "private" {
  count  = local.az_count
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[var.single_nat_gateway ? 0 : count.index].id
  }

  tags = {
    Name = "shopapi-private-rt-${count.index}-${var.environment}"
  }
}

resource "aws_route_table_association" "private" {
  count = local.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ── VPC Flow Logs (opcional, activado en prod) ────────────────────────────────

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc/flowlogs/shopapi-${var.environment}"
  retention_in_days = var.flow_log_retention_days

  tags = {
    Name = "shopapi-flow-logs-${var.environment}"
  }
}

data "aws_iam_policy_document" "flow_logs_trust" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "flow_logs_policy" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name               = "shopapi-flow-logs-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_trust[0].json
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name   = "FlowLogsCloudWatchAccess"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs_policy[0].json
}

resource "aws_flow_log" "main" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs[0].arn
  log_destination = aws_cloudwatch_log_group.flow_logs[0].arn

  tags = {
    Name = "shopapi-flow-log-${var.environment}"
  }
}
