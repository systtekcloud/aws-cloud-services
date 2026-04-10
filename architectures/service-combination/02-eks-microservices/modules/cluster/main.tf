variable "environment"    { type = string }
variable "cluster_version" { type = string default = "1.31" }
variable "vpc_id"          { type = string }
variable "subnet_ids"      { type = list(string) }

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ── EKS Cluster ───────────────────────────────────────────────────────────────

resource "aws_eks_cluster" "main" {
  name     = "saas-${var.environment}"
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true # En prod: false + VPN/bastion
    public_access_cidrs     = ["0.0.0.0/0"] # En prod: solo IPs conocidas
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# ── IAM: Cluster role ─────────────────────────────────────────────────────────

resource "aws_iam_role" "cluster" {
  name = "eks-cluster-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ── Fargate Profile (sin EC2 nodes) ──────────────────────────────────────────

resource "aws_iam_role" "fargate" {
  name = "eks-fargate-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks-fargate-pods.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "fargate_pod_execution" {
  role       = aws_iam_role.fargate.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
}

# Profile para namespaces de tenants (prefijo "tenant-")
resource "aws_eks_fargate_profile" "tenants" {
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "tenants-${var.environment}"
  pod_execution_role_arn = aws_iam_role.fargate.arn
  subnet_ids             = var.subnet_ids

  selector {
    namespace = "tenant-*"
  }

  tags = { Environment = var.environment }
}

# Profile para namespace platform
resource "aws_eks_fargate_profile" "platform" {
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "platform-${var.environment}"
  pod_execution_role_arn = aws_iam_role.fargate.arn
  subnet_ids             = var.subnet_ids

  selector { namespace = "kube-system" }
  selector { namespace = "platform" }
  selector { namespace = "argocd" }

  tags = { Environment = var.environment }
}

# ── IRSA (IAM Roles for Service Accounts) ────────────────────────────────────

# OIDC Provider del cluster (necesario para IRSA)
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# Helper: política de assume role para ServiceAccount específica
locals {
  oidc_issuer = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

# IRSA para AWS Load Balancer Controller
resource "aws_iam_role" "alb_controller" {
  name = "eks-alb-controller-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
          "${local.oidc_issuer}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess" # En prod: policy más restrictiva
}

output "cluster_name"            { value = aws_eks_cluster.main.name }
output "cluster_endpoint"        { value = aws_eks_cluster.main.endpoint }
output "cluster_ca"              { value = aws_eks_cluster.main.certificate_authority[0].data }
output "oidc_provider_arn"       { value = aws_iam_openid_connect_provider.eks.arn }
output "oidc_issuer"             { value = local.oidc_issuer }
output "alb_controller_role_arn" { value = aws_iam_role.alb_controller.arn }
