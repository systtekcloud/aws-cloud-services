# _modules/networking/flow_logs.tf
#
# VPC Flow Logs a CloudWatch Logs.
# Captura ACCEPT y REJECT en todos los ENIs de la VPC.
# El validate.sh consultara este Log Group con CloudWatch Insights
# para mostrar los paquetes rechazados en puertos efimeros.

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/lab06-flow-logs-${var.environment}"
  retention_in_days = 1
  tags              = { Name = "lab06-flow-logs-${var.environment}" }
}

resource "aws_iam_role" "flow_logs" {
  name = "lab06-flow-logs-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "lab06-flow-logs-policy-${var.environment}"
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

resource "aws_flow_log" "this" {
  vpc_id          = aws_vpc.this.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
  tags            = { Name = "lab06-flow-log-${var.environment}" }
}
