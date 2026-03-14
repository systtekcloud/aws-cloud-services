# =============================================================================
# outputs.tf — Valores necesarios para validación y debugging
# =============================================================================

output "consumer_instance_id" {
  description = "ID de la EC2 consumer en VPC-A (usar con SSM Session Manager)"
  value       = aws_instance.consumer.id
}

output "provider_instance_id" {
  description = "ID de la EC2 provider en VPC-B"
  value       = aws_instance.provider.id
}

output "vpc_a_id" {
  description = "VPC-A ID (consumer)"
  value       = aws_vpc.a.id
}

output "vpc_b_id" {
  description = "VPC-B ID (provider)"
  value       = aws_vpc.b.id
}

output "vpc_a_cidr" {
  description = "CIDR de VPC-A"
  value       = aws_vpc.a.cidr_block
}

output "vpc_b_cidr" {
  description = "CIDR de VPC-B — igual que VPC-A, de ahí el nombre del lab"
  value       = aws_vpc.b.cidr_block
}

output "nlb_dns_name" {
  description = "DNS del NLB en VPC-B (solo accesible desde VPC-B o via PrivateLink)"
  value       = aws_lb.provider.dns_name
}

output "endpoint_service_name" {
  description = "Nombre del Endpoint Service (com.amazonaws.vpce.eu-west-1.vpce-svc-XXXX)"
  value       = aws_vpc_endpoint_service.provider.service_name
}

output "endpoint_dns_name" {
  description = "DNS del Interface Endpoint en VPC-A — usar este hostname en el curl de validación"
  value       = aws_vpc_endpoint.consumer.dns_entry[0]["dns_name"]
}

output "endpoint_private_ip" {
  description = "IP privada de la ENI del Interface Endpoint en la subnet de VPC-A (10.0.1.x)"
  value       = aws_vpc_endpoint.consumer.dns_entry[0]["dns_name"]
}

output "ssm_session_command" {
  description = "Comando para iniciar sesión SSM en el consumer EC2"
  value       = "aws ssm start-session --target ${aws_instance.consumer.id} --region eu-west-1"
}

output "curl_test_command" {
  description = "Comando curl para probar PrivateLink (ejecutar dentro de la sesión SSM)"
  value       = "curl -s http://${aws_vpc_endpoint.consumer.dns_entry[0]["dns_name"]}:${var.http_port}/"
}

output "summary" {
  description = "Resumen del lab y comandos de validación"
  value = <<-EOT

    ============================================================
    Lab01 — PrivateLink con CIDRs solapados
    ============================================================

    VPC-A CIDR : ${aws_vpc.a.cidr_block}  (Consumer)
    VPC-B CIDR : ${aws_vpc.b.cidr_block}  (Provider)
    → Ambas VPCs tienen el MISMO CIDR — VPC Peering sería imposible

    Consumer EC2  : ${aws_instance.consumer.id}
    Provider EC2  : ${aws_instance.provider.id}
    NLB (VPC-B)   : ${aws_lb.provider.dns_name}
    Endpoint DNS  : ${aws_vpc_endpoint.consumer.dns_entry[0]["dns_name"]}

    ── Validación ──────────────────────────────────────────────
    1. Iniciar sesión SSM:
       aws ssm start-session --target ${aws_instance.consumer.id} --region eu-west-1

    2. Dentro de la sesión, probar PrivateLink:
       curl -s http://${aws_vpc_endpoint.consumer.dns_entry[0]["dns_name"]}:${var.http_port}/

    3. Esperar respuesta JSON de VPC-B confirmando que el tráfico llegó.

    ── Cleanup ─────────────────────────────────────────────────
    cd terragrunt && terragrunt destroy
    ============================================================
  EOT
}
