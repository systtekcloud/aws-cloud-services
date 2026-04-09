output "kinesis_stream_name" {
  description = "Nombre del Kinesis Data Stream"
  value       = aws_kinesis_stream.events.name
}

output "kinesis_stream_arn" {
  description = "ARN del Kinesis Data Stream"
  value       = aws_kinesis_stream.events.arn
}

output "firehose_stream_name" {
  description = "Nombre del delivery stream Firehose"
  value       = aws_kinesis_firehose_delivery_stream.raw.name
}

output "firehose_stream_arn" {
  description = "ARN del delivery stream Firehose"
  value       = aws_kinesis_firehose_delivery_stream.raw.arn
}
