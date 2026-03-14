# =============================================================================
# Lab05 — Terraform: 3-Tier Full Stack
# Aurora MySQL + RDS Proxy + DynamoDB + ElastiCache Redis + Lambda + SNS
# =============================================================================

# ─── VPC ──────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "vpc-lab05" }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_public_a_cidr
  availability_zone       = var.az_a
  map_public_ip_on_launch = true
  tags                    = { Name = "subnet-public-a-lab05", Tier = "public" }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_public_b_cidr
  availability_zone       = var.az_b
  map_public_ip_on_launch = true
  tags                    = { Name = "subnet-public-b-lab05", Tier = "public" }
}

resource "aws_subnet" "app_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_app_a_cidr
  availability_zone = var.az_a
  tags              = { Name = "subnet-app-a-lab05", Tier = "app" }
}

resource "aws_subnet" "app_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_app_b_cidr
  availability_zone = var.az_b
  tags              = { Name = "subnet-app-b-lab05", Tier = "app" }
}

resource "aws_subnet" "db_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_db_a_cidr
  availability_zone = var.az_a
  tags              = { Name = "subnet-db-a-lab05", Tier = "db" }
}

resource "aws_subnet" "db_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_db_b_cidr
  availability_zone = var.az_b
  tags              = { Name = "subnet-db-b-lab05", Tier = "db" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "igw-lab05" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "eip-nat-lab05" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id
  tags          = { Name = "nat-lab05" }
  depends_on    = [aws_internet_gateway.igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "rt-public-lab05" }
}

resource "aws_route_table" "private_app" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "rt-private-app-lab05" }
}

resource "aws_route_table" "private_db" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "rt-private-db-lab05" }
}

resource "aws_route_table_association" "public_a"   { subnet_id = aws_subnet.public_a.id; route_table_id = aws_route_table.public.id }
resource "aws_route_table_association" "public_b"   { subnet_id = aws_subnet.public_b.id; route_table_id = aws_route_table.public.id }
resource "aws_route_table_association" "app_a"      { subnet_id = aws_subnet.app_a.id;    route_table_id = aws_route_table.private_app.id }
resource "aws_route_table_association" "app_b"      { subnet_id = aws_subnet.app_b.id;    route_table_id = aws_route_table.private_app.id }
resource "aws_route_table_association" "db_a"       { subnet_id = aws_subnet.db_a.id;     route_table_id = aws_route_table.private_db.id }
resource "aws_route_table_association" "db_b"       { subnet_id = aws_subnet.db_b.id;     route_table_id = aws_route_table.private_db.id }

# ─── VPC ENDPOINT DYNAMODB (Gateway) ──────────────────────────────────────────
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private_app.id, aws_route_table.private_db.id]
  tags              = { Name = "vpce-dynamodb-lab05" }
}

# ─── SECURITY GROUPS ──────────────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name        = "sg-alb-lab05"
  description = "ALB — inbound HTTP/S from internet"
  vpc_id      = aws_vpc.main.id

  ingress { from_port = 80;  to_port = 80;  protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 443; to_port = 443; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0;   to_port = 0;   protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }
  tags = { Name = "sg-alb-lab05" }
}

resource "aws_security_group" "app" {
  name        = "sg-app-lab05"
  description = "App tier — inbound from ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
  tags = { Name = "sg-app-lab05" }
}

resource "aws_security_group" "aurora" {
  name        = "sg-aurora-lab05"
  description = "Aurora — inbound MySQL from App tier"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
  egress { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
  tags = { Name = "sg-aurora-lab05" }
}

resource "aws_security_group" "redis" {
  name        = "sg-redis-lab05"
  description = "Redis — inbound from App tier"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
  egress { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
  tags = { Name = "sg-redis-lab05" }
}

# ─── AURORA MYSQL ─────────────────────────────────────────────────────────────
resource "aws_db_subnet_group" "aurora" {
  name       = "aurora-lab05-subnetgroup"
  subnet_ids = [aws_subnet.db_a.id, aws_subnet.db_b.id]
  tags       = { Name = "aurora-lab05-subnetgroup" }
}

resource "random_password" "aurora" {
  length           = 20
  special          = false
}

resource "aws_secretsmanager_secret" "aurora" {
  name = var.aurora_secret_id
  tags = { Name = var.aurora_secret_id }
}

resource "aws_secretsmanager_secret_version" "aurora" {
  secret_id = aws_secretsmanager_secret.aurora.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.aurora.result
    host     = aws_rds_cluster.aurora.endpoint
    port     = 3306
    dbname   = var.aurora_db_name
  })
}

resource "aws_rds_cluster" "aurora" {
  cluster_identifier      = var.aurora_cluster_id
  engine                  = "aurora-mysql"
  engine_version          = var.aurora_engine_version
  database_name           = var.aurora_db_name
  master_username         = "admin"
  master_password         = random_password.aurora.result
  db_subnet_group_name    = aws_db_subnet_group.aurora.name
  vpc_security_group_ids  = [aws_security_group.aurora.id]
  backup_retention_period = 1
  skip_final_snapshot     = true
  storage_encrypted       = true
  deletion_protection     = false

  tags = { Name = var.aurora_cluster_id }
}

resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${var.aurora_cluster_id}-writer"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = var.aurora_instance_class
  engine             = "aurora-mysql"
  availability_zone  = var.az_a
  promotion_tier     = 1

  tags = { Name = "${var.aurora_cluster_id}-writer", Role = "writer" }
}

resource "aws_rds_cluster_instance" "reader" {
  identifier         = "${var.aurora_cluster_id}-reader"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = var.aurora_instance_class
  engine             = "aurora-mysql"
  availability_zone  = var.az_b
  promotion_tier     = 0

  tags = { Name = "${var.aurora_cluster_id}-reader", Role = "reader" }
}

# ─── RDS PROXY ────────────────────────────────────────────────────────────────
resource "aws_iam_role" "rds_proxy" {
  name = "rds-proxy-lab05-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "rds_proxy_secrets" {
  name = "AllowSecretsManager"
  role = aws_iam_role.rds_proxy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = aws_secretsmanager_secret.aurora.arn
    }]
  })
}

resource "aws_db_proxy" "aurora" {
  name                   = var.aurora_proxy_id
  debug_logging          = false
  engine_family          = "MYSQL"
  idle_client_timeout    = 1800
  require_tls            = false
  role_arn               = aws_iam_role.rds_proxy.arn
  vpc_security_group_ids = [aws_security_group.aurora.id]
  vpc_subnet_ids         = [aws_subnet.db_a.id, aws_subnet.db_b.id]

  auth {
    auth_scheme = "SECRETS"
    secret_arn  = aws_secretsmanager_secret.aurora.arn
    iam_auth    = "DISABLED"
  }

  tags = { Name = var.aurora_proxy_id }
}

resource "aws_db_proxy_default_target_group" "aurora" {
  db_proxy_name = aws_db_proxy.aurora.name
}

resource "aws_db_proxy_target" "aurora" {
  db_proxy_name          = aws_db_proxy.aurora.name
  target_group_name      = aws_db_proxy_default_target_group.aurora.name
  db_cluster_identifier  = aws_rds_cluster.aurora.id
}

# ─── DYNAMODB ─────────────────────────────────────────────────────────────────
resource "aws_dynamodb_table" "catalog" {
  name         = var.dynamo_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }
  attribute {
    name = "GSI1PK"
    type = "S"
  }
  attribute {
    name = "GSI1SK"
    type = "S"
  }

  global_secondary_index {
    name            = "GSI1-categoria-precio"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  tags = { Name = var.dynamo_table_name }
}

# ─── SNS ──────────────────────────────────────────────────────────────────────
resource "aws_sns_topic" "orders" {
  name = var.sns_topic_name
  tags = { Name = var.sns_topic_name }
}

# ─── LAMBDA ───────────────────────────────────────────────────────────────────
resource "aws_iam_role" "lambda" {
  name = "lambda-lab05-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_dynamodb" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaDynamoDBExecutionRole"
}

resource "aws_iam_role_policy" "lambda_sns" {
  name = "AllowSNSPublish"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sns:Publish"]
      Resource = aws_sns_topic.orders.arn
    }]
  })
}

data "archive_file" "lambda" {
  type        = "zip"
  output_path = "${path.module}/lambda_function.zip"
  source {
    content  = <<PYTHON
import json, os, boto3
sns = boto3.client("sns")
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]

def lambda_handler(event, context):
    processed = 0
    for record in event.get("Records", []):
        event_name = record["eventName"]
        new_image  = record.get("dynamodb", {}).get("NewImage", {})
        old_image  = record.get("dynamodb", {}).get("OldImage", {})
        pk = new_image.get("PK", {}).get("S") or old_image.get("PK", {}).get("S", "")

        if event_name == "INSERT" and pk.startswith("PEDIDO#"):
            pedido_id = pk.replace("PEDIDO#", "")
            sns.publish(TopicArn=SNS_TOPIC_ARN,
                Subject=f"Nuevo pedido {pedido_id}",
                Message=json.dumps({"evento":"PEDIDO_CREADO","pedido_id":pedido_id}))
            processed += 1
        elif event_name == "MODIFY" and pk.startswith("PEDIDO#"):
            new_estado = new_image.get("estado", {}).get("S")
            old_estado = old_image.get("estado", {}).get("S")
            if new_estado and new_estado != old_estado:
                sns.publish(TopicArn=SNS_TOPIC_ARN,
                    Subject=f"Pedido {pk.replace('PEDIDO#','')} actualizado",
                    Message=json.dumps({"evento":"PEDIDO_ACTUALIZADO","estado_nuevo":new_estado}))
                processed += 1
        elif event_name == "REMOVE" and pk.startswith("CART#"):
            uid = record.get("userIdentity", {})
            if "dynamodb.amazonaws.com" in uid.get("principalId", ""):
                print(f"[CARRITO_ABANDONADO] {pk}")
                processed += 1
    return {"statusCode": 200, "processed": processed}
PYTHON
    filename = "lambda_function.py"
  }
}

resource "aws_lambda_function" "catalog_stream" {
  function_name    = var.lambda_function_name
  role             = aws_iam_role.lambda.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.orders.arn
    }
  }

  tags = { Name = var.lambda_function_name }
}

resource "aws_lambda_event_source_mapping" "dynamo_stream" {
  event_source_arn               = aws_dynamodb_table.catalog.stream_arn
  function_name                  = aws_lambda_function.catalog_stream.arn
  starting_position              = "LATEST"
  batch_size                     = 10
  maximum_retry_attempts         = 2
}

# ─── ELASTICACHE REDIS ────────────────────────────────────────────────────────
resource "aws_elasticache_subnet_group" "redis" {
  name       = "redis-lab05-subnetgroup"
  subnet_ids = [aws_subnet.db_a.id, aws_subnet.db_b.id]
  tags       = { Name = "redis-lab05-subnetgroup" }
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = var.redis_cluster_id
  description                = "Redis lab05 — session store + cache"
  node_type                  = var.redis_node_type
  engine_version             = var.redis_engine_version
  num_cache_clusters         = 2
  parameter_group_name       = "default.redis7"
  subnet_group_name          = aws_elasticache_subnet_group.redis.name
  security_group_ids         = [aws_security_group.redis.id]
  automatic_failover_enabled = true
  multi_az_enabled           = true
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  snapshot_retention_limit   = 0

  tags = { Name = var.redis_cluster_id }
}

# ─── CLOUDWATCH ALARMS ────────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "aurora_cpu" {
  alarm_name          = "aurora-lab05-high-cpu"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.aurora.id
  }
  alarm_description = "Aurora CPU > 80% for 10 minutes"
  tags              = { Name = "aurora-lab05-high-cpu" }
}

resource "aws_cloudwatch_metric_alarm" "redis_cache_hit" {
  alarm_name          = "redis-lab05-low-hit-rate"
  namespace           = "AWS/ElastiCache"
  metric_name         = "CacheHitRate"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "LessThanThreshold"
  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.redis.id
  }
  alarm_description = "Redis cache hit rate < 80%"
  tags              = { Name = "redis-lab05-low-hit-rate" }
}

resource "aws_cloudwatch_metric_alarm" "dynamo_throttle" {
  alarm_name          = "dynamo-lab05-write-throttle"
  namespace           = "AWS/DynamoDB"
  metric_name         = "WriteThrottleEvents"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  dimensions = {
    TableName = aws_dynamodb_table.catalog.name
  }
  alarm_description = "DynamoDB write throttles > 10 in 5 minutes"
  tags              = { Name = "dynamo-lab05-write-throttle" }
}
