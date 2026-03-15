# =============================================================================
# flow_logs.tf — VPC Flow Logs para visualizar qué tráfico pasa por NAT GW
#
# Flow Logs captura metadatos de cada flujo de red: src IP, dst IP, bytes,
# acción (ACCEPT/REJECT), etc. NO captura el contenido del paquete.
#
# Qué buscaremos en los logs:
#   - Flujos donde srcaddr = IP de EC2-B Y dstaddr = IP pública del NAT GW
#     → esto indica tráfico S3 pasando por NAT
#   - Flujos donde srcaddr = IP de EC2-A Y dstaddr = prefix list S3
#     → esto va directo al Gateway Endpoint (distinto dstaddr)
#
# Formato de log: ${srcaddr} ${dstaddr} ${bytes} ${action}
# =============================================================================

# CloudWatch Log Group para los Flow Logs
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/flow-logs/${var.prefix}"
  retention_in_days = var.flow_log_retention_days # 1 día — solo para el lab

  tags = { Name = "${var.prefix}-flow-logs" }
}

# IAM Role para que VPC pueda escribir en CloudWatch
resource "aws_iam_role" "flow_logs" {
  name = "${var.prefix}-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "${var.prefix}-flow-logs-policy"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}

# Flow Log sobre la VPC completa (captura todos los ENIs, incluido NAT GW)
resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL" # ACCEPT + REJECT
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn

  # Formato custom para facilitar el parsing en validate.sh
  log_format = "$${srcaddr} $${dstaddr} $${bytes} $${action} $${protocol} $${srcport} $${dstport}"

  tags = { Name = "${var.prefix}-flow-log" }
}
