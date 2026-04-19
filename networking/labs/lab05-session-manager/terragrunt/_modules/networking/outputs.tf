# _modules/networking/outputs.tf

output "instance_id" {
  value       = aws_instance.this.id
  description = "Instance ID de la EC2 — usado en SSM start-session y Run Command"
}

output "instance_private_ip" {
  value       = aws_instance.this.private_ip
  description = "IP privada de la EC2"
}

output "vpc_id" {
  value       = aws_vpc.this.id
  description = "ID de la VPC"
}

output "ssm_mode" {
  value       = var.ssm_mode
  description = "Modo activo — usado en validate.sh para saber qué resultado esperar"
}

output "endpoint_ids" {
  value       = var.ssm_mode == "endpoints" ? [for ep in aws_vpc_endpoint.ssm : ep.id] : []
  description = "IDs de los Interface Endpoints (solo en modo endpoints)"
}
