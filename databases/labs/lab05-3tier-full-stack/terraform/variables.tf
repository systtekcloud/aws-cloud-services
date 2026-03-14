# =============================================================================
# Lab05 — Variables: 3-Tier Full Stack
# =============================================================================

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "project" {
  description = "Project tag"
  type        = string
  default     = "db-labs"
}

variable "lab" {
  description = "Lab tag"
  type        = string
  default     = "lab05"
}

variable "env" {
  description = "Environment tag"
  type        = string
  default     = "lab"
}

# ─── VPC ──────────────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_a" {
  description = "Primary availability zone"
  type        = string
  default     = "eu-west-1a"
}

variable "az_b" {
  description = "Secondary availability zone"
  type        = string
  default     = "eu-west-1b"
}

variable "subnet_public_a_cidr" {
  type    = string
  default = "10.20.0.0/24"
}

variable "subnet_public_b_cidr" {
  type    = string
  default = "10.20.1.0/24"
}

variable "subnet_app_a_cidr" {
  type    = string
  default = "10.20.10.0/24"
}

variable "subnet_app_b_cidr" {
  type    = string
  default = "10.20.11.0/24"
}

variable "subnet_db_a_cidr" {
  type    = string
  default = "10.20.20.0/24"
}

variable "subnet_db_b_cidr" {
  type    = string
  default = "10.20.21.0/24"
}

# ─── AURORA ───────────────────────────────────────────────────────────────────
variable "aurora_cluster_id" {
  description = "Aurora cluster identifier"
  type        = string
  default     = "aurora-lab05"
}

variable "aurora_db_name" {
  description = "Initial database name"
  type        = string
  default     = "ecommerce"
}

variable "aurora_instance_class" {
  description = "Aurora instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "aurora_engine_version" {
  description = "Aurora MySQL engine version"
  type        = string
  default     = "8.0.mysql_aurora.3.04.0"
}

variable "aurora_secret_id" {
  description = "Secrets Manager secret name for Aurora credentials"
  type        = string
  default     = "lab05/aurora/admin"
}

# ─── RDS PROXY ────────────────────────────────────────────────────────────────
variable "aurora_proxy_id" {
  description = "RDS Proxy identifier"
  type        = string
  default     = "aurora-lab05-proxy"
}

# ─── DYNAMODB ─────────────────────────────────────────────────────────────────
variable "dynamo_table_name" {
  description = "DynamoDB table name for catalog"
  type        = string
  default     = "ecommerce-catalog"
}

# ─── REDIS ────────────────────────────────────────────────────────────────────
variable "redis_cluster_id" {
  description = "ElastiCache Redis replication group ID"
  type        = string
  default     = "redis-lab05"
}

variable "redis_node_type" {
  description = "Redis node instance type"
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_engine_version" {
  description = "Redis engine version"
  type        = string
  default     = "7.1"
}

# ─── LAMBDA ───────────────────────────────────────────────────────────────────
variable "lambda_function_name" {
  description = "Lambda function name for DynamoDB Streams processor"
  type        = string
  default     = "ecommerce-catalog-stream"
}

variable "sns_topic_name" {
  description = "SNS topic name for order notifications"
  type        = string
  default     = "ecommerce-pedidos-notif"
}
