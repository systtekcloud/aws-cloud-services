output "certificate_arn" {
  value       = aws_acm_certificate.wildcard.arn
  description = "ARN del certificado ACM wildcard"
}

output "https_listener_arn" {
  value       = aws_lb_listener.https.arn
  description = "ARN del Listener HTTPS del ALB"
}

output "app_url" {
  value       = "https://${aws_route53_record.app.fqdn}"
  description = "URL pública de la app"
}

output "global_accelerator_ips" {
  value       = aws_globalaccelerator_accelerator.main.ip_sets[0].ip_addresses
  description = "IPs anycast del Global Accelerator"
}

output "global_accelerator_arn" {
  value       = aws_globalaccelerator_accelerator.main.id
  description = "ARN del Global Accelerator"
}
