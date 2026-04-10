# integration/labs/lab06-api-gateway/terraform/main.tf

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws    = { source = "hashicorp/aws",    version = "~> 5.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.0" }
  }
}

provider "aws" { region = "eu-west-1" }

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "lab06-apigw"
  tags = { Lab = "lab06-api-gateway", Module = "integration", Managed = "terraform" }
}

# ─── IAM ──────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "lambda_exec" {
  name = "${local.name_prefix}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ─── LAMBDA: backend ──────────────────────────────────────────────────────────

data "archive_file" "handler_zip" {
  type        = "zip"
  output_path = "/tmp/${local.name_prefix}-handler.zip"
  source {
    content  = <<-EOF
      import json, time
      def handler(event, context):
          method = event.get('httpMethod') or event.get('requestContext', {}).get('http', {}).get('method', 'UNKNOWN')
          return {
              'statusCode': 200,
              'headers': {'Content-Type': 'application/json'},
              'body': json.dumps({'message': 'OK', 'method': method, 'ts': time.time()})
          }
    EOF
    filename = "handler.py"
  }
}

resource "aws_lambda_function" "backend" {
  function_name    = "${local.name_prefix}-backend"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.handler_zip.output_path
  source_code_hash = data.archive_file.handler_zip.output_base64sha256
  timeout          = 10
  tags             = local.tags
}

# ─── LAMBDA: authorizer ───────────────────────────────────────────────────────

data "archive_file" "authorizer_zip" {
  type        = "zip"
  output_path = "/tmp/${local.name_prefix}-authorizer.zip"
  source {
    content  = <<-EOF
      VALID_TOKENS = {"token-admin": "user-admin", "token-readonly": "user-reader"}
      def handler(event, context):
          token = event.get('authorizationToken', '')
          effect = 'Allow' if token in VALID_TOKENS else 'Deny'
          principal = VALID_TOKENS.get(token, 'unauthorized')
          return {
              'principalId': principal,
              'policyDocument': {'Version': '2012-10-17', 'Statement': [
                  {'Action': 'execute-api:Invoke', 'Effect': effect, 'Resource': event['methodArn']}
              ]},
              'context': {'token': token}
          }
    EOF
    filename = "handler.py"
  }
}

resource "aws_lambda_function" "authorizer" {
  function_name    = "${local.name_prefix}-authorizer"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.authorizer_zip.output_path
  source_code_hash = data.archive_file.authorizer_zip.output_base64sha256
  timeout          = 5
  tags             = local.tags
}

# ─── REST API ─────────────────────────────────────────────────────────────────

resource "aws_api_gateway_rest_api" "main" {
  name        = "${local.name_prefix}-rest"
  description = "Lab 06 — REST API con Lambda Proxy, Authorizer y Usage Plan"
  tags        = local.tags
}

resource "aws_api_gateway_resource" "items" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "items"
}

resource "aws_api_gateway_authorizer" "token" {
  rest_api_id                      = aws_api_gateway_rest_api.main.id
  name                             = "token-authorizer"
  type                             = "TOKEN"
  authorizer_uri                   = aws_lambda_function.authorizer.invoke_arn
  authorizer_result_ttl_in_seconds = 300
  identity_source                  = "method.request.header.Authorization"
}

resource "aws_api_gateway_method" "get_items" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.items.id
  http_method   = "GET"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.token.id
  api_key_required = true
}

resource "aws_api_gateway_integration" "get_items" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.items.id
  http_method             = aws_api_gateway_method.get_items.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.backend.invoke_arn
}

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  depends_on  = [aws_api_gateway_integration.get_items]
  lifecycle { create_before_destroy = true }
}

resource "aws_api_gateway_stage" "dev" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  deployment_id = aws_api_gateway_deployment.main.id
  stage_name    = "dev"

  method_settings {
    resource_path = "/items/GET"
    http_method   = "GET"
    settings {
      throttling_rate_limit  = 10
      throttling_burst_limit = 20
    }
  }

  tags = local.tags
}

# API Key + Usage Plan
resource "aws_api_gateway_api_key" "free_tier" {
  name = "${local.name_prefix}-free-key"
  tags = local.tags
}

resource "aws_api_gateway_usage_plan" "free_tier" {
  name = "${local.name_prefix}-free-plan"
  api_stages {
    api_id = aws_api_gateway_rest_api.main.id
    stage  = aws_api_gateway_stage.dev.stage_name
  }
  throttle_settings {
    rate_limit  = 10
    burst_limit = 20
  }
  quota_settings {
    limit  = 1000
    period = "DAY"
  }
  tags = local.tags
}

resource "aws_api_gateway_usage_plan_key" "free_tier" {
  key_id        = aws_api_gateway_api_key.free_tier.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.free_tier.id
}

# Permisos Lambda
resource "aws_lambda_permission" "rest_backend" {
  statement_id  = "rest-api-invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backend.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*/*"
}

resource "aws_lambda_permission" "rest_authorizer" {
  statement_id  = "rest-authorizer-invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/authorizers/*"
}

# ─── HTTP API ─────────────────────────────────────────────────────────────────

resource "aws_apigatewayv2_api" "http" {
  name          = "${local.name_prefix}-http"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST"]
    allow_headers = ["Content-Type", "Authorization"]
  }
  tags = local.tags
}

resource "aws_apigatewayv2_integration" "http_backend" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.backend.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get_items" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "GET /items"
  target    = "integrations/${aws_apigatewayv2_integration.http_backend.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
  tags        = local.tags
}

resource "aws_lambda_permission" "http_backend" {
  statement_id  = "http-api-invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backend.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

# ─── OUTPUTS ──────────────────────────────────────────────────────────────────

output "rest_api_url"  { value = "${aws_api_gateway_stage.dev.invoke_url}/items" }
output "http_api_url"  { value = "${aws_apigatewayv2_api.http.api_endpoint}/items" }
output "api_key_value" {
  value     = aws_api_gateway_api_key.free_tier.value
  sensitive = true
}
