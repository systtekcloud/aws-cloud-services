variable "environment" { type = string }
variable "vpc_cidr"    { type = string default = "10.20.0.0/16" }

# ── VPC (ECS Fargate Tasks necesitan red) ────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "docs-pipeline-${var.environment}" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = { Name = "docs-private-${count.index}-${var.environment}" }
}

data "aws_availability_zones" "available" { state = "available" }

# NAT Gateway para que Fargate Tasks accedan a S3/DynamoDB/Step Functions
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.private[0].id # Adjunto a subnet privada para ECS
  depends_on    = [aws_internet_gateway.igw]
}

# VPC Endpoints (alternativa al NAT para S3/DynamoDB — más barato)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
}

data "aws_region" "current" {}

# ── Security Group para Fargate Tasks ────────────────────────────────────────

resource "aws_security_group" "fargate" {
  name   = "fargate-${var.environment}"
  vpc_id = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "fargate-${var.environment}" }
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "docs" {
  name = "docs-pipeline-${var.environment}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Environment = var.environment }
}

# ── ECR Repository (imagen Docker del procesador OCR) ────────────────────────

resource "aws_ecr_repository" "ocr_processor" {
  name                 = "ocr-processor-${var.environment}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Environment = var.environment }
}

# ── DynamoDB ──────────────────────────────────────────────────────────────────

resource "aws_dynamodb_table" "documentos" {
  name         = "documentos-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "doc_id"

  attribute {
    name = "doc_id"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
    projection_type = "ALL"
  }

  tags = { Environment = var.environment }
}

output "vpc_id"              { value = aws_vpc.main.id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "fargate_sg_id"      { value = aws_security_group.fargate.id }
output "ecs_cluster_name"   { value = aws_ecs_cluster.docs.name }
output "ecs_cluster_arn"    { value = aws_ecs_cluster.docs.arn }
output "ecr_repository_url" { value = aws_ecr_repository.ocr_processor.repository_url }
output "dynamodb_table_name"{ value = aws_dynamodb_table.documentos.name }
output "dynamodb_table_arn" { value = aws_dynamodb_table.documentos.arn }
