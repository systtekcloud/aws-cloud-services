# =============================================================================
# Lab01 — PrivateLink con CIDRs solapados
# main.tf — Versiones y data sources
#
# CONCEPTO CLAVE:
#   VPC Peering requiere CIDRs no solapados porque funciona a nivel de enrutamiento IP.
#   Si dos VPCs tienen el mismo CIDR, AWS no puede crear rutas sin ambigüedad.
#
#   PrivateLink NO depende de enrutamiento IP entre VPCs. El consumidor conecta a una
#   ENI (Elastic Network Interface) en su propia VPC, y AWS gestiona internamente el
#   reenvío al NLB del proveedor. Los CIDRs de las VPCs son irrelevantes.
# =============================================================================

# ---------------------------------------------------------------------------
# AMI — Amazon Linux 2023 (más reciente en eu-west-1)
# AL2023 incluye SSM Agent preinstalado → acceso via Session Manager sin SSH
# ---------------------------------------------------------------------------
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# ---------------------------------------------------------------------------
# Local values — prefijos y nombres de recursos
# ---------------------------------------------------------------------------
locals {
  name_prefix = var.prefix

  # El CIDR es el mismo en ambas VPCs (el lab demuestra que esto es válido con PrivateLink)
  common_tags = {
    Lab = "lab01-privatelink-cidr-overlap"
  }
}
