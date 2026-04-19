# _modules/networking/outputs.tf

output "alb_dns_name" {
  value       = aws_lb.this.dns_name
  description = "DNS del ALB — usado en validate.sh para los curl"
}

output "nacl_id" {
  value       = aws_network_acl.private.id
  description = "ID del NACL privado — validate.sh elimina/restaura la regla 200"
}

output "instance_id" {
  value       = aws_instance.this.id
  description = "Instance ID de la EC2"
}

output "flow_log_group" {
  value       = aws_cloudwatch_log_group.flow_logs.name
  description = "Nombre del Log Group de Flow Logs — usado en CloudWatch Insights query"
}

output "vpc_id" {
  value       = aws_vpc.this.id
  description = "ID de la VPC"
}

output "private_subnet_cidr" {
  value       = aws_subnet.private.cidr_block
  description = "CIDR de la subnet privada — usado en la query de Flow Logs"
}
