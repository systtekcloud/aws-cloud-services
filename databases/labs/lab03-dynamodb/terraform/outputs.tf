output "table_name" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.ecommerce.name
}

output "table_arn" {
  description = "DynamoDB table ARN"
  value       = aws_dynamodb_table.ecommerce.arn
}

output "stream_arn" {
  description = "DynamoDB Stream ARN (null if streams disabled)"
  value       = var.enable_streams ? aws_dynamodb_table.ecommerce.stream_arn : null
}

output "gsi_names" {
  description = "List of GSI names"
  value       = ["GSI1", "GSI2"]
}

output "billing_mode" {
  description = "Current billing mode"
  value       = aws_dynamodb_table.ecommerce.billing_mode
}

output "ttl_enabled" {
  description = "Whether TTL is enabled"
  value       = var.ttl_attribute != ""
}

output "lambda_function_name" {
  description = "Lambda function name for Stream processing (null if disabled)"
  value       = var.enable_lambda_trigger ? aws_lambda_function.stream_processor[0].function_name : null
}

output "lambda_arn" {
  description = "Lambda function ARN (null if disabled)"
  value       = var.enable_lambda_trigger ? aws_lambda_function.stream_processor[0].arn : null
}

output "sns_alerts_arn" {
  description = "SNS topic ARN for CloudWatch alerts"
  value       = aws_sns_topic.alerts.arn
}

output "example_queries" {
  description = "Example CLI queries to run from EC2"
  value = {
    ap1_query  = "aws dynamodb query --table-name ${aws_dynamodb_table.ecommerce.name} --key-condition-expression 'PK = :pk' --expression-attribute-values '{\":pk\": {\"S\": \"CUSTOMER#1001\"}}'"
    ap3_gsi1   = "aws dynamodb query --table-name ${aws_dynamodb_table.ecommerce.name} --index-name GSI1 --key-condition-expression 'GSI1PK = :pk' --expression-attribute-values '{\":pk\": {\"S\": \"ORDER#ORD-001\"}}'"
    ap4_gsi2   = "aws dynamodb query --table-name ${aws_dynamodb_table.ecommerce.name} --index-name GSI2 --key-condition-expression 'GSI2PK = :status' --expression-attribute-values '{\":status\": {\"S\": \"STATUS#pending\"}}'"
  }
}
