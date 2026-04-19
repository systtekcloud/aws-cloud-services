# _modules/networking/outputs.tf
#
# Outputs necesarios para el script de validación.
# El validate.sh lee estos valores con: terragrunt output -raw <nombre>

output "vpc_id" {
  value       = aws_vpc.this.id
  description = "ID de la VPC del lab"
}

output "ec2_a_instance_id" {
  value       = aws_instance.ec2_a.id
  description = "Instance ID de EC2-A (AZ-a) — usado en SSM Run Command"
}

output "ec2_b_instance_id" {
  value       = aws_instance.ec2_b.id
  description = "Instance ID de EC2-B (AZ-b) — usado en SSM Run Command"
}

output "nat_gateway_a_id" {
  value       = aws_nat_gateway.this[0].id
  description = "ID del NAT Gateway en AZ-a — el validate.sh lo elimina para simular fallo"
}

output "nat_gateway_b_id" {
  value       = var.nat_ha ? aws_nat_gateway.this[1].id : null
  description = "ID del NAT Gateway en AZ-b (solo si nat_ha=true)"
}

output "nat_ha_enabled" {
  value       = var.nat_ha
  description = "Indica si el modo HA está activado — usado en validate.sh para saber qué resultado esperar"
}

output "az_a" {
  value       = local.az_a
  description = "AZ donde está NAT GW-a y EC2-A"
}

output "az_b" {
  value       = local.az_b
  description = "AZ donde está EC2-B (y NAT GW-b si nat_ha=true)"
}
