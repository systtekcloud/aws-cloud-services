variable "environment"    { type = string }
variable "vpc_id"         { type = string }
variable "subnet_ids"     { type = list(string) }
variable "cluster_name"   { type = string }

# ── Cognito User Pool (autenticación de tenants) ──────────────────────────────

resource "aws_cognito_user_pool" "saas" {
  name = "saas-tenants-${var.environment}"

  # Grupos: un grupo por tenant + rol
  # tenant-acme-admin, tenant-acme-user, tenant-beta-admin, etc.

  password_policy {
    minimum_length    = 12
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }

  schema {
    name                = "tenant_id"
    attribute_data_type = "String"
    mutable             = false # No se puede cambiar el tenant del usuario
    required            = false
    string_attribute_constraints {
      min_length = 1
      max_length = 64
    }
  }

  schema {
    name                = "role"
    attribute_data_type = "String"
    mutable             = true
    required            = false
    string_attribute_constraints {
      min_length = 1
      max_length = 32
    }
  }

  tags = { Environment = var.environment }
}

resource "aws_cognito_user_pool_client" "api" {
  name         = "saas-api-client-${var.environment}"
  user_pool_id = aws_cognito_user_pool.saas.id

  generate_secret = false # SPA/mobile no puede guardar secrets

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["email", "openid", "profile"]
  callback_urls                        = ["https://app.saas.example.com/callback"]
  logout_urls                          = ["https://app.saas.example.com/logout"]
  supported_identity_providers         = ["COGNITO"]
}

# ── NLB (requerido para VPC Link de API Gateway) ──────────────────────────────

resource "aws_lb" "nlb" {
  name               = "saas-nlb-${var.environment}"
  internal           = true # Solo accesible desde VPC (API GW via VPC Link)
  load_balancer_type = "network"
  subnets            = var.subnet_ids

  tags = { Environment = var.environment }
}

# Target group apuntando al NodePort del servicio EKS
resource "aws_lb_target_group" "api" {
  name        = "saas-api-${var.environment}"
  port        = 30080 # NodePort del servicio Kubernetes
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip" # Para Fargate (sin nodos EC2)

  health_check {
    protocol = "TCP"
    port     = "30080"
  }
}

resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# ── API Gateway VPC Link ──────────────────────────────────────────────────────

resource "aws_api_gateway_vpc_link" "eks" {
  name        = "saas-eks-${var.environment}"
  target_arns = [aws_lb.nlb.arn]

  tags = { Environment = var.environment }
}

# ── API Gateway REST ──────────────────────────────────────────────────────────

resource "aws_api_gateway_rest_api" "saas" {
  name        = "saas-api-${var.environment}"
  description = "SaaS B2B API — multi-tenant con Cognito auth"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# Cognito Authorizer
resource "aws_api_gateway_authorizer" "cognito" {
  name          = "cognito-authorizer"
  rest_api_id   = aws_api_gateway_rest_api.saas.id
  type          = "COGNITO_USER_POOLS"
  provider_arns = [aws_cognito_user_pool.saas.arn]
}

# Usage Plans por tier de tenant
resource "aws_api_gateway_usage_plan" "basic" {
  name = "saas-basic-${var.environment}"

  api_stages {
    api_id = aws_api_gateway_rest_api.saas.id
    stage  = aws_api_gateway_deployment.saas.stage_name
  }

  throttle_settings {
    rate_limit  = 10   # req/s
    burst_limit = 20
  }

  quota_settings {
    limit  = 10000 # req/mes
    period = "MONTH"
  }
}

resource "aws_api_gateway_usage_plan" "enterprise" {
  name = "saas-enterprise-${var.environment}"

  api_stages {
    api_id = aws_api_gateway_rest_api.saas.id
    stage  = aws_api_gateway_deployment.saas.stage_name
  }

  throttle_settings {
    rate_limit  = 1000
    burst_limit = 5000
  }

  quota_settings {
    limit  = 10000000
    period = "MONTH"
  }
}

# Recurso y método (proxy a EKS via VPC Link)
resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.saas.id
  parent_id   = aws_api_gateway_rest_api.saas.root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "proxy_any" {
  rest_api_id   = aws_api_gateway_rest_api.saas.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
  api_key_required = true

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "proxy_vpclink" {
  rest_api_id             = aws_api_gateway_rest_api.saas.id
  resource_id             = aws_api_gateway_resource.proxy.id
  http_method             = aws_api_gateway_method.proxy_any.http_method
  integration_http_method = "ANY"
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_lb.nlb.dns_name}/{proxy}"
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.eks.id

  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
    # Propagar tenant_id del JWT al backend como header
    "integration.request.header.X-Tenant-ID" = "context.authorizer.claims['custom:tenant_id']"
  }
}

resource "aws_api_gateway_deployment" "saas" {
  rest_api_id = aws_api_gateway_rest_api.saas.id
  stage_name  = var.environment

  depends_on = [aws_api_gateway_integration.proxy_vpclink]
}

output "api_endpoint"       { value = aws_api_gateway_deployment.saas.invoke_url }
output "cognito_pool_id"    { value = aws_cognito_user_pool.saas.id }
output "cognito_client_id"  { value = aws_cognito_user_pool_client.api.id }
output "vpc_link_id"        { value = aws_api_gateway_vpc_link.eks.id }
output "nlb_arn"            { value = aws_lb.nlb.arn }
