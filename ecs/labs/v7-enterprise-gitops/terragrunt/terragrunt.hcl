# =============================================================================
# Terragrunt Root Configuration — ShopAPI Enterprise
# =============================================================================
#
# Este archivo es la configuracion RAIZ de Terragrunt. Todos los modulos
# hijos lo incluyen con `include "root"`, heredando automaticamente:
#   - La configuracion del backend S3 remoto (estado separado por modulo)
#   - El bloque provider "aws" con default_tags
#
# Por que este enfoque (DRY):
#   Sin Terragrunt: hay que copiar backend.tf y provider.tf en cada modulo.
#   Con Terragrunt: se define una vez aqui y se genera automaticamente.
#
# Documentacion Gruntwork: https://terragrunt.gruntwork.io/docs/getting-started/quick-start/
# =============================================================================

locals {
  # -------------------------------------------------------------------------
  # Leer el archivo env.hcl del entorno actual.
  # find_in_parent_folders("env.hcl") busca hacia arriba en el arbol de
  # directorios hasta encontrar un archivo llamado "env.hcl".
  # Por ejemplo, desde dev/ecs-service/ encontrara dev/env.hcl.
  # -------------------------------------------------------------------------
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))

  # Extraer variables del entorno para uso local en este archivo
  environment = local.env_vars.locals.environment
  aws_region  = local.env_vars.locals.aws_region
  account_id  = local.env_vars.locals.account_id
}

# =============================================================================
# BACKEND REMOTO S3
# =============================================================================
#
# Terragrunt genera automaticamente backend.tf en cada modulo.
# La key incluye el entorno y la ruta relativa del modulo, garantizando
# que cada modulo tenga su propio state file completamente aislado.
#
# Ejemplo de keys generadas:
#   dev/dev/vpc/terraform.tfstate
#   dev/dev/ecs-service/terraform.tfstate
#   prod/prod/ecs-service/terraform.tfstate
# =============================================================================
remote_state {
  backend = "s3"

  # generate: Terragrunt crea backend.tf automaticamente en cada modulo
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    # El bucket incluye el account_id para evitar colisiones entre cuentas
    bucket = "shopapi-terraform-state-${local.account_id}"

    # path_relative_to_include() devuelve la ruta relativa del modulo
    # respecto a este archivo raiz. Por ejemplo: "dev/ecs-service"
    key = "${local.environment}/${path_relative_to_include()}/terraform.tfstate"

    region = local.aws_region

    # Cifrado en reposo obligatorio para estado con informacion sensible
    encrypt = true

    # DynamoDB para locking: evita que dos applies simultaneos corrompan el estado
    dynamodb_table = "shopapi-terraform-locks"

    # Activar acceso a versiones anteriores del estado (permite rollback)
    # Requiere que el bucket tenga versionado habilitado
    skip_bucket_versioning = false

    # Metadatos de S3 para identificar el state file
    s3_bucket_tags = {
      Project   = "shopapi"
      ManagedBy = "terragrunt"
    }
  }
}

# =============================================================================
# PROVIDER AWS — Generado automaticamente en todos los modulos
# =============================================================================
#
# En lugar de copiar provider.tf en cada modulo, Terragrunt lo genera
# con el valor correcto de region y los default_tags del entorno.
#
# default_tags aplica automaticamente estos tags a TODOS los recursos
# creados por Terraform en este entorno, sin necesidad de declararlos
# en cada recurso individual.
# =============================================================================
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"

  contents = <<-EOF
    # Archivo generado automaticamente por Terragrunt — NO editar manualmente
    # Para modificar, editar el bloque generate "provider" en el root terragrunt.hcl

    terraform {
      required_version = ">= 1.6.0"

      required_providers {
        aws = {
          source  = "hashicorp/aws"
          version = "~> 5.0"
        }
      }
    }

    provider "aws" {
      region = "${local.aws_region}"

      # default_tags aplica estos tags a todos los recursos del entorno
      # sin necesidad de declararlos en cada recurso individualmente
      default_tags {
        tags = {
          Project     = "shopapi"
          Environment = "${local.environment}"
          ManagedBy   = "terragrunt"
          Repository  = "shopapi/infrastructure"
        }
      }
    }
  EOF
}
