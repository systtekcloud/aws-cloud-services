################################################################################
# Lab EC2 v4 — Terraform
# ACM wildcard + ALB HTTPS + Route53 Alias + Global Accelerator
################################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws"; version = "~> 5.0" }
  }
}

# Provider regional (ALB, ACM, SG)
provider "aws" {
  alias  = "regional"
  region = var.aws_region
  default_tags {
    tags = { Project = var.project; Lab = "v4"; ManagedBy = "Terraform" }
  }
}

# Global Accelerator requiere us-east-1
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = { Project = var.project; Lab = "v4"; ManagedBy = "Terraform" }
  }
}

locals {
  fqdn        = "${var.subdomain}.${var.domain}"
  name_prefix = "${var.project}-${var.environment}"
}

################################################################################
# ACM Certificate — wildcard para *.domain + domain raíz
################################################################################

resource "aws_acm_certificate" "wildcard" {
  provider          = aws.regional
  domain_name       = "*.${var.domain}"
  subject_alternative_names = [var.domain]
  validation_method = "DNS"

  lifecycle { create_before_destroy = true }
}

# Validación DNS automática en Route53
resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = var.hosted_zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 300
  records = [each.value.record]

  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "wildcard" {
  provider                = aws.regional
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

################################################################################
# ALB — Listener HTTPS:443 + Redirect HTTP→HTTPS
################################################################################

# SG: añadir regla 443
resource "aws_security_group_rule" "alb_https_ingress" {
  provider          = aws.regional
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = var.alb_sg_id
  description       = "HTTPS desde internet"
}

resource "aws_lb_listener" "https" {
  provider          = aws.regional
  load_balancer_arn = var.alb_arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.wildcard.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = var.tg_arn
  }
}

# HTTP:80 → redirect permanente a HTTPS
# NOTA: El listener HTTP de v1 se modifica aquí
resource "aws_lb_listener" "http_redirect" {
  provider          = aws.regional
  load_balancer_arn = var.alb_arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

################################################################################
# Route53 — A Alias record con EvaluateTargetHealth
################################################################################

resource "aws_route53_record" "app" {
  zone_id = var.hosted_zone_id
  name    = local.fqdn
  type    = "A"

  set_identifier = "primary-${var.aws_region}"

  weighted_routing_policy {
    weight = 100
  }

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

################################################################################
# Global Accelerator
################################################################################

resource "aws_globalaccelerator_accelerator" "main" {
  provider        = aws.us_east_1
  name            = "${local.name_prefix}-ga"
  ip_address_type = "IPV4"
  enabled         = true

  attributes {
    flow_logs_enabled = false
  }
}

resource "aws_globalaccelerator_listener" "main" {
  provider        = aws.us_east_1
  accelerator_arn = aws_globalaccelerator_accelerator.main.id
  protocol        = "TCP"

  port_range { from_port = 80;  to_port = 80  }
  port_range { from_port = 443; to_port = 443 }
}

resource "aws_globalaccelerator_endpoint_group" "main" {
  provider     = aws.us_east_1
  listener_arn = aws_globalaccelerator_listener.main.id

  endpoint_group_region         = var.aws_region
  health_check_path             = "/health"
  health_check_interval_seconds = 10
  threshold_count               = 2

  endpoint_configuration {
    endpoint_id                    = var.alb_arn
    weight                         = 100
    client_ip_preservation_enabled = true
  }
}
