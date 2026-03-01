# =============================================================================
# Lab v1 — ShopAPI en ECS Fargate
# Terraform: Outputs — Valores importantes tras el apply
#
# Uso para ver los outputs:
#   terraform output
#   terraform output ecr_repository_url
#   terraform output -json | jq .
# =============================================================================

# =============================================================================
# OUTPUTS DE ECR
# =============================================================================

output "ecr_repository_url" {
  description = "URI completo del repositorio ECR. Usar para docker push y en Task Definitions"
  value       = aws_ecr_repository.shopapi_api.repository_url
}

output "ecr_repository_arn" {
  description = "ARN del repositorio ECR"
  value       = aws_ecr_repository.shopapi_api.arn
}

output "ecr_image_url_versioned" {
  description = "URI completo de la imagen con el tag de version especifica"
  value       = "${aws_ecr_repository.shopapi_api.repository_url}:${var.app_version}"
}

output "ecr_image_url_latest" {
  description = "URI completo de la imagen con el tag 'latest'"
  value       = "${aws_ecr_repository.shopapi_api.repository_url}:latest"
}

# =============================================================================
# OUTPUTS DE ECS
# =============================================================================

output "cluster_arn" {
  description = "ARN del cluster ECS. Necesario para RunTask y aws ecs describe-clusters"
  value       = aws_ecs_cluster.shopapi.arn
}

output "cluster_name" {
  description = "Nombre del cluster ECS"
  value       = aws_ecs_cluster.shopapi.name
}

output "task_definition_arn" {
  description = "ARN completo de la Task Definition registrada (incluye la revision)"
  value       = aws_ecs_task_definition.shopapi_api.arn
}

output "task_definition_family" {
  description = "Nombre de la familia de la Task Definition"
  value       = aws_ecs_task_definition.shopapi_api.family
}

output "task_definition_revision" {
  description = "Numero de revision de la Task Definition activa"
  value       = aws_ecs_task_definition.shopapi_api.revision
}

# =============================================================================
# OUTPUTS DE CLOUDWATCH
# =============================================================================

output "log_group_name" {
  description = "Nombre del CloudWatch Log Group donde se envian los logs del contenedor"
  value       = aws_cloudwatch_log_group.ecs_shopapi.name
}

output "log_group_arn" {
  description = "ARN del CloudWatch Log Group"
  value       = aws_cloudwatch_log_group.ecs_shopapi.arn
}

# =============================================================================
# OUTPUTS DE IAM
# =============================================================================

output "execution_role_arn" {
  description = "ARN del IAM Execution Role. Usar en Task Definitions como executionRoleArn"
  value       = aws_iam_role.ecs_execution_role.arn
}

output "execution_role_name" {
  description = "Nombre del IAM Execution Role"
  value       = aws_iam_role.ecs_execution_role.name
}

# =============================================================================
# OUTPUTS DE UTILIDAD — Comandos listos para usar
# =============================================================================

output "cmd_run_task" {
  description = "Comando de ejemplo para ejecutar un RunTask (sustituir SUBNET_ID y SG_ID)"
  value       = <<-EOT

    aws ecs run-task \
      --cluster ${aws_ecs_cluster.shopapi.name} \
      --task-definition ${aws_ecs_task_definition.shopapi_api.family} \
      --launch-type FARGATE \
      --count 1 \
      --network-configuration "awsvpcConfiguration={subnets=[SUBNET_ID],securityGroups=[SG_ID],assignPublicIp=ENABLED}" \
      --region ${var.aws_region}
  EOT
}

output "cmd_view_logs" {
  description = "Comando para ver los log streams del contenedor en CloudWatch"
  value       = <<-EOT

    aws logs describe-log-streams \
      --log-group-name ${aws_cloudwatch_log_group.ecs_shopapi.name} \
      --region ${var.aws_region}
  EOT
}

output "cmd_docker_push" {
  description = "Comandos para autenticar Docker y hacer push de la imagen a ECR"
  value       = <<-EOT

    # 1. Autenticar Docker con ECR
    aws ecr get-login-password --region ${var.aws_region} \
      | docker login --username AWS --password-stdin \
        ${var.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com

    # 2. Build y push
    docker build -t ${aws_ecr_repository.shopapi_api.repository_url}:${var.app_version} .
    docker push ${aws_ecr_repository.shopapi_api.repository_url}:${var.app_version}
  EOT
}
