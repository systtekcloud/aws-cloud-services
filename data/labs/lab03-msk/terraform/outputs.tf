output "msk_cluster_arn" {
  description = "MSK Serverless cluster ARN"
  value       = aws_msk_serverless_cluster.main.arn
}

output "msk_cluster_name" {
  description = "MSK Serverless cluster name"
  value       = aws_msk_serverless_cluster.main.cluster_name
}

output "security_group_id" {
  description = "Security group ID for MSK"
  value       = aws_security_group.msk.id
}

output "s3_connect_bucket" {
  description = "S3 bucket for MSK Connect sink"
  value       = aws_s3_bucket.connect.bucket
}

output "msk_connect_role_arn" {
  description = "IAM role ARN for MSK Connect"
  value       = aws_iam_role.msk_connect.arn
}
