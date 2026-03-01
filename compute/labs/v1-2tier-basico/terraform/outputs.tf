################################################################################
# Lab EC2 v1 — Outputs Terraform
################################################################################

output "vpc_id" {
  description = "ID de la VPC creada"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs de las subnets públicas (ALB)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs de las subnets privadas (EC2)"
  value       = aws_subnet.private[*].id
}

output "alb_dns_name" {
  description = "DNS del ALB para pruebas: curl http://<alb_dns_name>/health"
  value       = aws_lb.app.dns_name
}

output "alb_arn" {
  description = "ARN del ALB (usado por v4 para Route53 Alias)"
  value       = aws_lb.app.arn
}

output "alb_zone_id" {
  description = "Hosted Zone ID del ALB (para Route53 Alias records)"
  value       = aws_lb.app.zone_id
}

output "target_group_arn" {
  description = "ARN del Target Group"
  value       = aws_lb_target_group.app.arn
}

output "asg_name" {
  description = "Nombre del Auto Scaling Group"
  value       = aws_autoscaling_group.app.name
}

output "launch_template_id" {
  description = "ID del Launch Template"
  value       = aws_launch_template.app.id
}

output "ec2_sg_id" {
  description = "SG de las instancias EC2 (usado por v2 para RDS/ElastiCache)"
  value       = aws_security_group.ec2.id
}

output "s3_bucket_name" {
  description = "Nombre del bucket S3 de artefactos"
  value       = aws_s3_bucket.artefactos.id
}

output "iam_instance_profile_arn" {
  description = "ARN del Instance Profile EC2"
  value       = aws_iam_instance_profile.ec2.arn
}

output "test_commands" {
  description = "Comandos rápidos de validación"
  value       = <<-EOT
    # Health check
    curl http://${aws_lb.app.dns_name}/health

    # Ver instancias del ASG
    aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names ${aws_autoscaling_group.app.name} \
      --query 'AutoScalingGroups[0].Instances[*].[InstanceId,AvailabilityZone,HealthStatus]' \
      --output table

    # Round-robin test (10 peticiones)
    for i in $(seq 1 10); do
      curl -s http://${aws_lb.app.dns_name}/ | jq -r '.instance_id + " " + .az'
    done
  EOT
}
