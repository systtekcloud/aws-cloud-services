################################################################################
# Módulo reutilizable: VPC
# Wrapper del código de v1 — centraliza VPC para todos los entornos
# Este módulo es llamado por Terragrunt desde dev/ y prod/
################################################################################

# Reutilizar el código de v1 directamente
# En un proyecto real, este módulo estaría en un repositorio separado
# y se referenciaría con: source = "git::https://github.com/org/tf-modules.git//vpc?ref=v1.0"

module "vpc_v1" {
  source = "../../../v1-2tier-basico/terraform"

  aws_region            = var.aws_region
  project               = var.project
  environment           = var.environment
  vpc_cidr              = var.vpc_cidr
  public_subnets_cidrs  = var.public_subnets_cidrs
  private_subnets_cidrs = var.private_subnets_cidrs
  enable_nat_gateway    = var.enable_nat_gateway
  single_nat_gateway    = var.single_nat_gateway

  # Solo VPC — sin compute (ASG, ALB se crean en el módulo compute)
  asg_min_size         = 0
  asg_max_size         = 0
  asg_desired_capacity = 0
}

# Outputs re-exportados para dependency {} en Terragrunt
output "vpc_id"             { value = module.vpc_v1.vpc_id }
output "public_subnet_ids"  { value = module.vpc_v1.public_subnet_ids }
output "private_subnet_ids" { value = module.vpc_v1.private_subnet_ids }
output "ec2_sg_id"          { value = module.vpc_v1.ec2_sg_id }
