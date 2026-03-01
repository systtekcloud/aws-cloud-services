# ── Lab v5: OIDC Provider + GitHub Actions IAM Role ──────────────────────────
# Este Terraform provisiona los recursos IAM necesarios para que
# GitHub Actions pueda autenticarse en AWS sin access keys estáticas.
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = { Project = "shopapi", Lab = "v5-cicd", ManagedBy = "terraform" }
  }
}

data "aws_caller_identity" "current" {}

# ── OIDC Provider para GitHub Actions ────────────────────────────────────────
# GitHub usa OIDC para emitir tokens JWT que AWS puede verificar directamente.
# Esto elimina la necesidad de almacenar AWS_ACCESS_KEY_ID/SECRET en GitHub Secrets.

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]

  # Thumbprint del certificado TLS de GitHub — valor oficial de GitHub
  # Ref: https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# ── IAM Role para GitHub Actions ──────────────────────────────────────────────

data "aws_iam_policy_document" "github_trust" {
  statement {
    sid     = "AllowGitHubActionsOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      # StringLike permite comodines: cualquier branch/environment del repo
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.project_prefix}-github-actions-role"
  description        = "Role asumido por GitHub Actions via OIDC para deploy de ShopAPI"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
  max_session_duration = 3600
}

# ── Políticas del Role ────────────────────────────────────────────────────────

# 1. ECR: build y push de imágenes
data "aws_iam_policy_document" "ecr_push" {
  statement {
    sid    = "ECRGetToken"
    effect = "Allow"
    actions = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # GetAuthorizationToken no admite resource ARN
  }

  statement {
    sid    = "ECRPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:GetRepositoryPolicy",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
      "ecr:DescribeImages",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [
      "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.project_prefix}/*"
    ]
  }
}

# 2. ECS: registrar task def + actualizar service
data "aws_iam_policy_document" "ecs_deploy" {
  statement {
    sid    = "ECSDescribe"
    effect = "Allow"
    actions = [
      "ecs:DescribeTaskDefinition",
      "ecs:DescribeServices",
      "ecs:DescribeClusters",
      "ecs:ListTaskDefinitions",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ECSRegisterAndDeploy"
    effect = "Allow"
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:UpdateService",
    ]
    resources = [
      "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/${var.project_prefix}-*",
      "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/${var.project_prefix}-cluster/${var.project_prefix}-*",
    ]
  }

  statement {
    sid    = "IAMPassRole"
    effect = "Allow"
    actions = ["iam:PassRole"]
    # GitHub Actions necesita PassRole para registrar task definitions con execution/task role
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_prefix}-*-role"
    ]
    condition {
      test     = "StringLike"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Adjuntar las dos políticas al role
resource "aws_iam_role_policy" "ecr_push" {
  name   = "ECRPushPolicy"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.ecr_push.json
}

resource "aws_iam_role_policy" "ecs_deploy" {
  name   = "ECSDeployPolicy"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.ecs_deploy.json
}
