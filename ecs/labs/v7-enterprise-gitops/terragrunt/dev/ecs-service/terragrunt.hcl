# =============================================================================
# Modulo ECS Service — Entorno DEV
# =============================================================================
#
# Este archivo configura el ECS Service de ShopAPI para el entorno de desarrollo.
# Hereda el backend y el provider del root terragrunt.hcl, y las variables
# del entorno de dev/env.hcl.
#
# Dependencias:
#   - vpc: necesita los subnets privados y el VPC ID
#   - ecs-cluster: necesita el ARN y nombre del cluster
#   - alb: necesita el ARN del target group
# =============================================================================

terraform {
  # La doble barra (//) separa la ruta del repositorio de la ruta dentro del modulo.
  # Permite versionar modulos: git::https://github.com/org/modules.git//ecs-service?ref=v2.0.0
  source = "../../../_modules//ecs-service"
}

# Incluir la configuracion raiz: genera backend.tf y provider.tf automaticamente
include "root" {
  path = find_in_parent_folders()
}

# Leer las variables del entorno dev
# expose = true: permite referenciar include.env.locals.* en este archivo
include "env" {
  path   = find_in_parent_folders("env.hcl")
  expose = true
}

# =============================================================================
# DEPENDENCIAS — Terragrunt las resuelve en orden automaticamente
# =============================================================================
#
# Cuando se ejecuta `terragrunt run-all apply` desde dev/, Terragrunt
# calcula el grafo de dependencias y aplica en el orden correcto:
# vpc → alb → ecs-cluster → ecs-service (alb y ecs-cluster en paralelo)

dependency "vpc" {
  config_path = "../vpc"

  # mock_outputs: usados por `terragrunt plan` cuando vpc no existe aun.
  # Permite que el CI/CD ejecute `plan` en una PR antes de que haya infraestructura.
  mock_outputs = {
    private_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000002"]
    vpc_id             = "vpc-00000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "ecs_cluster" {
  config_path = "../ecs-cluster"

  mock_outputs = {
    cluster_arn  = "arn:aws:ecs:eu-west-1:123456789012:cluster/shopapi-cluster-dev-mock"
    cluster_name = "shopapi-cluster-dev-mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "alb" {
  config_path = "../alb"

  mock_outputs = {
    target_group_arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:targetgroup/shopapi-dev-mock/abcdef123456"
    alb_dns_name     = "shopapi-dev-mock.eu-west-1.elb.amazonaws.com"
    alb_security_group_id = "sg-00000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# =============================================================================
# INPUTS — Variables pasadas al modulo Terraform _modules/ecs-service
# =============================================================================
inputs = {
  # --- Identificacion ---
  environment  = include.env.locals.environment
  service_name = "shopapi-api"

  # --- Cluster donde se despliega el servicio ---
  cluster_name = dependency.ecs_cluster.outputs.cluster_name
  cluster_arn  = dependency.ecs_cluster.outputs.cluster_arn

  # --- Networking: subnets privados (las tasks no son directamente accesibles) ---
  vpc_id             = dependency.vpc.outputs.vpc_id
  private_subnet_ids = dependency.vpc.outputs.private_subnet_ids

  # --- Load Balancer: el ALB enruta el trafico a este target group ---
  target_group_arn      = dependency.alb.outputs.target_group_arn
  alb_security_group_id = dependency.alb.outputs.alb_security_group_id

  # --- Configuracion de la Task Definition ---
  # La imagen se sobreescribe en el despliegue desde CI/CD con la tag exacta
  container_image = "public.ecr.aws/shopapi/api:latest"
  container_port  = 8080
  cpu             = include.env.locals.api_cpu
  memory          = include.env.locals.api_memory

  # --- Escalado del servicio ---
  desired_count = include.env.locals.api_desired_count
  min_tasks     = include.env.locals.api_min_tasks
  max_tasks     = include.env.locals.api_max_tasks

  # --- Fargate Capacity Providers: mezcla Spot/On-Demand ---
  # En dev: 80% Spot (weight 4) + 20% On-Demand (weight 1)
  # La tarea base (base = 1) garantiza al menos 1 task On-Demand siempre
  capacity_provider_strategy = [
    {
      capacity_provider = "FARGATE_SPOT"
      weight            = include.env.locals.fargate_spot_weight
      base              = 0
    },
    {
      capacity_provider = "FARGATE"
      weight            = include.env.locals.fargate_on_demand_weight
      base              = 1 # Garantizar al menos 1 task On-Demand
    }
  ]

  # --- Observabilidad ---
  log_retention_days = include.env.locals.log_retention_days

  # --- Auto Scaling basado en CPU/Memoria ---
  # En dev: escala cuando CPU supera el 70% (umbral relajado)
  scale_up_cpu_threshold   = 70
  scale_down_cpu_threshold = 30

  # --- Programacion de scale-down nocturno (solo en dev) ---
  enable_scheduled_scaling = include.env.locals.enable_scheduled_scaling
  scale_down_cron          = include.env.locals.scale_down_cron
  scale_up_cron            = include.env.locals.scale_up_cron
}
