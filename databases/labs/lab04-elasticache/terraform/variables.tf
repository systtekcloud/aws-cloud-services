variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "project" {
  type    = string
  default = "db-labs"
}

variable "lab" {
  type    = string
  default = "lab04"
}

variable "env" {
  type    = string
  default = "lab"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
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

variable "redis_cluster_id" {
  description = "Replication Group ID"
  type        = string
  default     = "redis-lab-cluster"
}

variable "redis_node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_engine_version" {
  description = "Redis engine version"
  type        = string
  default     = "7.1"
}

variable "redis_num_clusters" {
  description = "Number of cache clusters (1 primary + N replicas)"
  type        = number
  default     = 2

  validation {
    condition     = var.redis_num_clusters >= 1 && var.redis_num_clusters <= 6
    error_message = "redis_num_clusters must be between 1 and 6."
  }
}

variable "redis_subnet_group" {
  type    = string
  default = "redis-lab-subnetgroup"
}

variable "enable_multi_az" {
  description = "Enable Multi-AZ with automatic failover"
  type        = bool
  default     = true
}

variable "at_rest_encryption" {
  description = "Enable encryption at rest"
  type        = bool
  default     = true
}

variable "transit_encryption" {
  description = "Enable TLS in transit"
  type        = bool
  default     = true
}

variable "snapshot_retention" {
  description = "Days to retain automatic snapshots (0 = disabled)"
  type        = number
  default     = 0
}
