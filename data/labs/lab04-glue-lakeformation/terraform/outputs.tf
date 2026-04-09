output "s3_raw_bucket" {
  description = "S3 bucket for raw CSV data"
  value       = aws_s3_bucket.raw.bucket
}

output "s3_processed_bucket" {
  description = "S3 bucket for processed Parquet data"
  value       = aws_s3_bucket.processed.bucket
}

output "s3_results_bucket" {
  description = "S3 bucket for Athena query results"
  value       = aws_s3_bucket.results.bucket
}

output "glue_database" {
  description = "Glue Catalog database name"
  value       = aws_glue_catalog_database.main.name
}

output "glue_crawler_name" {
  description = "Glue Crawler name"
  value       = aws_glue_crawler.sales_raw.name
}

output "glue_job_name" {
  description = "Glue ETL Job name"
  value       = aws_glue_job.csv_to_parquet.name
}

output "athena_workgroup" {
  description = "Athena workgroup name"
  value       = aws_athena_workgroup.main.name
}

output "glue_role_arn" {
  description = "IAM role ARN for Glue"
  value       = aws_iam_role.glue.arn
}
