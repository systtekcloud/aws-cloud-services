output "glue_database_name" {
  description = "Nombre de la base de datos en Glue Data Catalog"
  value       = aws_glue_catalog_database.data_lake.name
}

output "glue_role_arn" {
  description = "ARN del IAM role para Glue Crawlers y ETL Jobs"
  value       = aws_iam_role.glue.arn
}

output "athena_role_arn" {
  description = "ARN del IAM role para Athena"
  value       = aws_iam_role.athena.arn
}

output "athena_workgroup_name" {
  description = "Nombre del workgroup Athena"
  value       = aws_athena_workgroup.data_lake.name
}
