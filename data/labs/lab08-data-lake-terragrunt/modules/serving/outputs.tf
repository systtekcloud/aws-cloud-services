output "redshift_namespace_name" {
  description = "Nombre del namespace Redshift Serverless"
  value       = aws_redshiftserverless_namespace.data_lake.namespace_name
}

output "redshift_workgroup_name" {
  description = "Nombre del workgroup Redshift Serverless"
  value       = aws_redshiftserverless_workgroup.data_lake.workgroup_name
}

output "redshift_endpoint" {
  description = "Endpoint de conexión JDBC al workgroup"
  value       = aws_redshiftserverless_workgroup.data_lake.endpoint
}

output "redshift_role_arn" {
  description = "ARN del IAM role asociado a Redshift (para COPY y Spectrum)"
  value       = aws_iam_role.redshift.arn
}

output "spectrum_sql_ssm_parameter" {
  description = "SSM Parameter con el SQL para configurar Redshift Spectrum"
  value       = aws_ssm_parameter.redshift_spectrum_sql.name
}
