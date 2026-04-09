output "opensearch_domain_name" {
  description = "OpenSearch domain name"
  value       = aws_opensearch_domain.main.domain_name
}

output "opensearch_endpoint" {
  description = "OpenSearch REST API endpoint"
  value       = "https://${aws_opensearch_domain.main.endpoint}"
}

output "opensearch_dashboards_url" {
  description = "OpenSearch Dashboards URL"
  value       = "https://${aws_opensearch_domain.main.endpoint}/_dashboards"
}

output "opensearch_arn" {
  description = "OpenSearch domain ARN"
  value       = aws_opensearch_domain.main.arn
}

output "firehose_name" {
  description = "Firehose delivery stream name"
  value       = aws_kinesis_firehose_delivery_stream.opensearch.name
}

output "firehose_arn" {
  description = "Firehose delivery stream ARN"
  value       = aws_kinesis_firehose_delivery_stream.opensearch.arn
}

output "cwlogs_role_arn" {
  description = "IAM role ARN for CloudWatch Logs → Firehose subscription filter"
  value       = aws_iam_role.cwlogs.arn
}

output "s3_backup_bucket" {
  description = "S3 bucket for Firehose failed documents backup"
  value       = aws_s3_bucket.firehose_backup.bucket
}
