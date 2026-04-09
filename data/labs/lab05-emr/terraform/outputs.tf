output "emr_application_id" {
  description = "EMR Serverless application ID"
  value       = aws_emrserverless_application.spark.id
}

output "emr_application_arn" {
  description = "EMR Serverless application ARN"
  value       = aws_emrserverless_application.spark.arn
}

output "s3_input_bucket" {
  description = "S3 bucket for job input scripts and data"
  value       = aws_s3_bucket.input.bucket
}

output "s3_output_bucket" {
  description = "S3 bucket for job output"
  value       = aws_s3_bucket.output.bucket
}

output "s3_logs_bucket" {
  description = "S3 bucket for EMR logs"
  value       = aws_s3_bucket.logs.bucket
}

output "emr_role_arn" {
  description = "IAM role ARN for EMR Serverless job execution"
  value       = aws_iam_role.emr_serverless.arn
}
