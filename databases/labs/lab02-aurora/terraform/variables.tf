variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "project" {
  description = "Project tag for all resources"
  type        = string
  default     = "db-labs"
}

variable "lab" {
  description = "Lab identifier tag"
  type        = string
  default     = "lab02"
}

variable "env" {
  description = "Environment tag"
  type        = string
  default     = "lab"
}

# ---- Red ----
variable "vpc_cidr" {
  description = "VPC CIDR block. Must match lab01 if reusing."
  type        = string
  default     = "10.20.0.0/16"
}

variable "subnet_private_a_cidr" {
  type    = string
  default = "10.20.10.0/24"
}

variable "subnet_private_b_cidr" {
  type    = string
  default = "10.20.11.0/24"
}

variable "az_a" {
  type    = string
  default = "eu-west-1a"
}

variable "az_b" {
  type    = string
  default = "eu-west-1b"
}

# ---- Aurora Cluster ----
variable "aurora_cluster_id" {
  description = "Aurora DB cluster identifier"
  type        = string
  default     = "db-lab-aurora-cluster"
}

variable "aurora_writer_id" {
  description = "Aurora Writer instance identifier"
  type        = string
  default     = "db-lab-aurora-writer"
}

variable "aurora_reader_id" {
  description = "Aurora Reader instance identifier"
  type        = string
  default     = "db-lab-aurora-reader"
}

variable "aurora_engine" {
  description = "Aurora engine type"
  type        = string
  default     = "aurora-mysql"
}

variable "aurora_engine_version" {
  description = "Aurora MySQL engine version"
  type        = string
  default     = "8.0.mysql_aurora.3.04.0"
}

variable "aurora_instance_class" {
  description = "DB instance class. Aurora requires minimum db.t3.medium"
  type        = string
  default     = "db.t3.medium"

  validation {
    condition     = can(regex("^db\\.(t3|t4g|r6g|r7g|r6i|r7i)", var.aurora_instance_class))
    error_message = "Aurora requires at least db.t3.medium (not micro)."
  }
}

variable "aurora_db_name" {
  description = "Initial database name in the cluster"
  type        = string
  default     = "auroradb"
}

variable "aurora_master_user" {
  description = "Master username for Aurora cluster"
  type        = string
  default     = "admin"
}

variable "aurora_subnet_group" {
  description = "DB subnet group name for Aurora"
  type        = string
  default     = "aurora-lab-subnetgroup"
}

variable "backup_retention_days" {
  description = "Automated backup retention in days"
  type        = number
  default     = 1
}

variable "backtrack_window" {
  description = "Backtrack window in seconds (0 to disable). Aurora MySQL only."
  type        = number
  default     = 3600

  validation {
    condition     = var.backtrack_window >= 0 && var.backtrack_window <= 259200
    error_message = "Backtrack window must be between 0 and 259200 (72h)."
  }
}

variable "enable_reader" {
  description = "Create a Reader instance (adds ~db.t3.medium cost)"
  type        = bool
  default     = true
}

variable "reader_promotion_tier" {
  description = "Reader failover priority (0=highest, 15=lowest)"
  type        = number
  default     = 0
}

variable "enable_deletion_protection" {
  description = "Protect cluster from accidental deletion"
  type        = bool
  default     = false
}

variable "secret_id" {
  description = "Secrets Manager secret ID for Aurora credentials"
  type        = string
  default     = "lab02/aurora/admin"
}

variable "kms_key_arn" {
  description = "KMS key ARN for Aurora storage encryption. Leave empty to use aws/rds."
  type        = string
  default     = ""
}
