output "oidc_provider_arn" {
  description = "ARN del OIDC Provider — referenciar en trust policies futuras"
  value       = aws_iam_openid_connect_provider.github.arn
}

output "github_actions_role_arn" {
  description = "ARN del role a usar en el workflow (role-to-assume)"
  value       = aws_iam_role.github_actions.arn
}

output "github_secrets_to_set" {
  description = "Secretos a configurar en el repositorio de GitHub"
  value = {
    AWS_ACCOUNT_ID = data.aws_caller_identity.current.account_id
    AWS_REGION     = var.aws_region
  }
}
