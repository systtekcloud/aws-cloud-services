output "kda_application_name" {
  description = "KDA application name"
  value       = aws_kinesisanalyticsv2_application.main.name
}

output "kda_application_arn" {
  description = "KDA application ARN"
  value       = aws_kinesisanalyticsv2_application.main.arn
}

output "kds_source_name" {
  description = "KDS source stream name"
  value       = aws_kinesis_stream.source.name
}

output "kds_source_arn" {
  description = "KDS source stream ARN"
  value       = aws_kinesis_stream.source.arn
}

output "kds_output_name" {
  description = "KDS output stream name"
  value       = aws_kinesis_stream.output.name
}

output "kds_output_arn" {
  description = "KDS output stream ARN"
  value       = aws_kinesis_stream.output.arn
}
