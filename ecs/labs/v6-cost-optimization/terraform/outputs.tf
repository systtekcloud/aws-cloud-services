output "api_task_definition_arm64" {
  description = "ARN de la Task Definition ARM64 de la API"
  value       = aws_ecs_task_definition.api_arm64.arn
}

output "worker_task_definition_arm64" {
  description = "ARN de la Task Definition ARM64 del Worker"
  value       = aws_ecs_task_definition.worker_arm64.arn
}

output "vpc_endpoint_ids" {
  description = "IDs de los VPC Endpoints Interface creados"
  value       = var.enable_vpc_endpoints ? { for k, v in aws_vpc_endpoint.interface : k => v.id } : {}
}

output "s3_endpoint_id" {
  description = "ID del VPC Endpoint Gateway de S3"
  value       = var.enable_vpc_endpoints ? aws_vpc_endpoint.s3[0].id : null
}

output "cost_comparison" {
  description = "Resumen del ahorro estimado por las optimizaciones"
  value = {
    arm64_savings_pct       = "~20% en compute Fargate vs X86_64"
    spot_savings_pct        = "~66% en tasks FARGATE_SPOT vs FARGATE"
    vpc_endpoints_benefit   = "Elimina coste de transferencia NAT Gateway para servicios AWS"
    monthly_savings_example = "~$60/mes para 4 API + 2 Worker tasks (ver cost-analysis.md)"
  }
}

output "cmd_verify_arm64" {
  description = "Verificar que las tasks corren en ARM64"
  value       = "aws ecs describe-tasks --cluster shopapi-cluster --tasks $(aws ecs list-tasks --cluster shopapi-cluster --service-name shopapi-api --query 'taskArns[0]' --output text) --query 'tasks[0].{arch:attributes[?name==`ecs.cpu-architecture`].value|[0],platform:platformVersion}'"
}

output "cmd_spot_savings_estimate" {
  description = "Calcular ahorro de FARGATE_SPOT en el periodo actual"
  value       = "aws ce get-cost-and-usage --time-period Start=$(date -d 'last month' '+%Y-%m-01'),End=$(date '+%Y-%m-01') --granularity MONTHLY --filter '{\"Tags\":{\"Key\":\"Project\",\"Values\":[\"shopapi\"]}}' --metrics BlendedCost --group-by '[{\"Type\":\"DIMENSION\",\"Key\":\"USAGE_TYPE\"}]'"
}
