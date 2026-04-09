output "data_lake_bucket_id" {
  description = "Nombre del bucket S3 del data lake"
  value       = aws_s3_bucket.data_lake.id
}

output "data_lake_bucket_arn" {
  description = "ARN del bucket S3 del data lake"
  value       = aws_s3_bucket.data_lake.arn
}

output "raw_prefix" {
  description = "S3 URI de la zona raw"
  value       = "s3://${aws_s3_bucket.data_lake.id}/raw/"
}

output "processed_prefix" {
  description = "S3 URI de la zona processed"
  value       = "s3://${aws_s3_bucket.data_lake.id}/processed/"
}

output "curated_prefix" {
  description = "S3 URI de la zona curated"
  value       = "s3://${aws_s3_bucket.data_lake.id}/curated/"
}

output "scripts_prefix" {
  description = "S3 URI para scripts Glue/Spark"
  value       = "s3://${aws_s3_bucket.data_lake.id}/scripts/"
}

output "access_logs_bucket_id" {
  description = "Bucket de access logs"
  value       = aws_s3_bucket.access_logs.id
}
