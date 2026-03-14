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
  default = "lab03"
}

variable "env" {
  type    = string
  default = "lab"
}

variable "table_name" {
  description = "DynamoDB table name"
  type        = string
  default     = "ecommerce-orders"
}

variable "billing_mode" {
  description = "PAY_PER_REQUEST or PROVISIONED"
  type        = string
  default     = "PAY_PER_REQUEST"

  validation {
    condition     = contains(["PAY_PER_REQUEST", "PROVISIONED"], var.billing_mode)
    error_message = "billing_mode must be PAY_PER_REQUEST or PROVISIONED."
  }
}

variable "read_capacity" {
  description = "Read capacity units (only used when billing_mode=PROVISIONED)"
  type        = number
  default     = 5
}

variable "write_capacity" {
  description = "Write capacity units (only used when billing_mode=PROVISIONED)"
  type        = number
  default     = 5
}

variable "ttl_attribute" {
  description = "Name of the TTL attribute (empty string to disable)"
  type        = string
  default     = "ttl"
}

variable "enable_streams" {
  description = "Enable DynamoDB Streams"
  type        = bool
  default     = true
}

variable "stream_view_type" {
  description = "Stream view type when streams enabled"
  type        = string
  default     = "NEW_AND_OLD_IMAGES"
}

variable "enable_lambda_trigger" {
  description = "Create Lambda function and Event Source Mapping for Streams"
  type        = bool
  default     = true
}

variable "lambda_function_name" {
  type    = string
  default = "dynamodb-stream-processor"
}

variable "enable_pitr" {
  description = "Enable Point-in-Time Recovery"
  type        = bool
  default     = false
}

variable "alert_email" {
  description = "Email for CloudWatch alerts (optional, leave empty to skip SNS subscription)"
  type        = string
  default     = ""
}
