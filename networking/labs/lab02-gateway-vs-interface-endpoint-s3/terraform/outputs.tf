# =============================================================================
# outputs.tf — Valores para validación del lab
# =============================================================================

output "ec2_gw_instance_id" {
  description = "EC2-A (subnet con Gateway Endpoint) — usar con SSM"
  value       = aws_instance.ec2_gw.id
}

output "ec2_nat_instance_id" {
  description = "EC2-B (subnet sin Gateway Endpoint, solo NAT) — usar con SSM"
  value       = aws_instance.ec2_nat.id
}

output "ec2_gw_private_ip" {
  description = "IP privada de EC2-A"
  value       = aws_instance.ec2_gw.private_ip
}

output "ec2_nat_private_ip" {
  description = "IP privada de EC2-B"
  value       = aws_instance.ec2_nat.private_ip
}

output "nat_gateway_public_ip" {
  description = "IP pública del NAT Gateway — buscar esta IP en Flow Logs para ver qué tráfico pasa por NAT"
  value       = aws_eip.nat.public_ip
}

output "s3_bucket_name" {
  description = "Nombre del bucket S3 de test"
  value       = aws_s3_bucket.test.bucket
}

output "s3_endpoint_id" {
  description = "ID del Gateway Endpoint S3"
  value       = aws_vpc_endpoint.s3.id
}

output "cloudwatch_log_group" {
  description = "Nombre del Log Group de Flow Logs — para consultas manuales en CloudWatch"
  value       = aws_cloudwatch_log_group.flow_logs.name
}

output "summary" {
  description = "Resumen del lab y comandos de validación"
  value = <<-EOT

    ============================================================
    Lab02 — Gateway Endpoint vs NAT Gateway para S3
    ============================================================

    EC2-A (Gateway Endpoint): ${aws_instance.ec2_gw.id}  IP: ${aws_instance.ec2_gw.private_ip}
    EC2-B (NAT Gateway only): ${aws_instance.ec2_nat.id}  IP: ${aws_instance.ec2_nat.private_ip}
    NAT Gateway public IP   : ${aws_eip.nat.public_ip}
    S3 bucket               : ${aws_s3_bucket.test.bucket}
    Flow Logs               : ${aws_cloudwatch_log_group.flow_logs.name}

    ── Validación ──────────────────────────────────────────────
    ./validate.sh

    ── Cleanup ─────────────────────────────────────────────────
    cd terragrunt && terragrunt destroy
    ============================================================
  EOT
}
