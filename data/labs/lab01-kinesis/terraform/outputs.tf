output "kds_stream_name" {
  description = "KDS stream name"
  value       = aws_kinesis_stream.main.name
}

output "kds_stream_arn" {
  description = "KDS stream ARN"
  value       = aws_kinesis_stream.main.arn
}

output "kds_shard_count" {
  description = "Number of shards"
  value       = aws_kinesis_stream.main.shard_count
}

output "firehose_stream_name" {
  description = "Firehose delivery stream name"
  value       = aws_kinesis_firehose_delivery_stream.main.name
}

output "firehose_stream_arn" {
  description = "Firehose delivery stream ARN"
  value       = aws_kinesis_firehose_delivery_stream.main.arn
}

output "s3_bucket_name" {
  description = "S3 bucket name (Firehose destination)"
  value       = aws_s3_bucket.firehose.id
}

output "s3_bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.firehose.arn
}

output "lambda_function_name" {
  description = "Lambda transform function name"
  value       = aws_lambda_function.transform.function_name
}

output "lambda_function_arn" {
  description = "Lambda transform function ARN"
  value       = aws_lambda_function.transform.arn
}
