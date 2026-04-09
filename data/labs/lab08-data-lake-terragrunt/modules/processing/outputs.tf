output "glue_crawler_name" {
  description = "Nombre del Glue Crawler para raw/"
  value       = aws_glue_crawler.raw.name
}

output "glue_job_name" {
  description = "Nombre del Glue ETL Job"
  value       = aws_glue_job.raw_to_processed.name
}

output "emr_application_id" {
  description = "ID de la aplicación EMR Serverless"
  value       = aws_emrserverless_application.spark.id
}

output "emr_application_arn" {
  description = "ARN de la aplicación EMR Serverless"
  value       = aws_emrserverless_application.spark.arn
}

output "emr_role_arn" {
  description = "ARN del IAM role para EMR Serverless job runs"
  value       = aws_iam_role.emr_serverless.arn
}
