# _modules/networking/outputs.tf

output "ec2_a_instance_id" {
  value       = aws_instance.ec2_a.id
  description = "Instance ID de EC2-A (VPC-A) — usado en SSM Run Command"
}

output "ec2_b_instance_id" {
  value       = aws_instance.ec2_b.id
  description = "Instance ID de EC2-B (VPC-B)"
}

output "ec2_c_instance_id" {
  value       = aws_instance.ec2_c.id
  description = "Instance ID de EC2-C (VPC-C)"
}

output "ec2_a_private_ip" {
  value       = aws_instance.ec2_a.private_ip
  description = "IP privada de EC2-A — objetivo de ping desde EC2-C"
}

output "ec2_c_private_ip" {
  value       = aws_instance.ec2_c.private_ip
  description = "IP privada de EC2-C — objetivo de ping desde EC2-A"
}

output "connectivity_mode" {
  value       = var.connectivity_mode
  description = "Modo de conectividad activo — usado en validate.sh para saber qué resultado esperar"
}

output "tgw_id" {
  value       = var.connectivity_mode == "tgw" ? aws_ec2_transit_gateway.this[0].id : null
  description = "ID del Transit Gateway (solo en modo tgw)"
}
