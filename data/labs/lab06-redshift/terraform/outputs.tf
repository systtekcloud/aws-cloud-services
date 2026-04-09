output "namespace_name" {
  description = "Redshift Serverless namespace name"
  value       = aws_redshiftserverless_namespace.main.namespace_name
}

output "namespace_id" {
  description = "Redshift Serverless namespace ID"
  value       = aws_redshiftserverless_namespace.main.id
}

output "workgroup_name" {
  description = "Redshift Serverless workgroup name"
  value       = aws_redshiftserverless_workgroup.main.workgroup_name
}

output "workgroup_arn" {
  description = "Redshift Serverless workgroup ARN"
  value       = aws_redshiftserverless_workgroup.main.arn
}

output "endpoint_address" {
  description = "Redshift Serverless endpoint address"
  value       = aws_redshiftserverless_workgroup.main.endpoint[0].address
}

output "endpoint_port" {
  description = "Redshift Serverless endpoint port"
  value       = aws_redshiftserverless_workgroup.main.endpoint[0].port
}

output "s3_bucket" {
  description = "S3 bucket for data loading"
  value       = aws_s3_bucket.data.bucket
}

output "iam_role_arn" {
  description = "IAM role ARN for Redshift S3 + Spectrum access"
  value       = aws_iam_role.redshift.arn
}

output "connection_info" {
  description = "Connection details for Redshift"
  value = {
    host     = aws_redshiftserverless_workgroup.main.endpoint[0].address
    port     = 5439
    database = "dev"
    username = var.admin_username
  }
}
