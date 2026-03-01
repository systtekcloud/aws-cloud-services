# Lab v7 — Arquitectura Enterprise GitOps con Terragrunt y Atmos

## Objetivo

Este lab transforma la infraestructura de ShopAPI de una arquitectura single-account con Terraform plano (v1-v6) a una arquitectura enterprise multi-entorno usando:

- **Terragrunt**: eliminar la repetición de configuraciones Terraform (DRY — Don't Repeat Yourself)
- **Atmos**: orquestar stacks completos y workflows de despliegue
- **GitOps completo**: flujo automatizado PR → Plan → Aprobación → Apply

Al finalizar, el mismo código base gestiona `dev`, `staging` y `prod` con configuraciones independientes, estado de Terraform separado por entorno, y un flujo de despliegue auditado y reproducible.

---

## El problema del Terraform plano (por qué necesitamos Terragrunt)

Después del lab v6, la infraestructura funciona, pero tiene un problema de escalabilidad: cuando se necesita replicar el mismo stack para dev, staging y prod, hay que copiar y pegar bloques enteros de configuración.

### Problema 1: Backend repetido en cada módulo

Sin Terragrunt, cada carpeta de módulo necesita su propio `backend.tf`:

```hcl
# dev/vpc/backend.tf
terraform {
  backend "s3" {
    bucket         = "shopapi-terraform-state-123456789"
    key            = "dev/vpc/terraform.tfstate"
    region         = "eu-west-1"
    encrypt        = true
    dynamodb_table = "shopapi-terraform-locks"
  }
}

# staging/vpc/backend.tf  <- copia exacta, solo cambia la key
terraform {
  backend "s3" {
    bucket         = "shopapi-terraform-state-123456789"
    key            = "staging/vpc/terraform.tfstate"  # solo esto cambia
    region         = "eu-west-1"
    encrypt        = true
    dynamodb_table = "shopapi-terraform-locks"
  }
}
```

Con 4 módulos y 3 entornos, son **12 bloques backend** mantenidos manualmente.

### Problema 2: Provider repetido en cada módulo

El bloque `provider "aws"` con los `default_tags` necesita aparecer en cada módulo:

```hcl
# Repetido 12 veces (4 módulos x 3 entornos)
provider "aws" {
  region = "eu-west-1"
  default_tags {
    tags = {
      Project     = "shopapi"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}
```

Si se cambia un tag, hay que actualizarlo en los 12 lugares.

### Problema 3: Terraform Workspaces no resuelve el problema

Terraform tiene Workspaces como solución para multi-entorno, pero tienen limitaciones importantes:

| Característica | Terraform Workspaces | Terragrunt |
|----------------|---------------------|------------|
| Estado separado por entorno | Si (en el mismo bucket/path) | Si (paths completamente distintos) |
| Variables distintas por entorno | No (necesita condicionales en codigo) | Si (env.hcl por entorno) |
| Backend diferente por entorno | No (mismo backend, diferente workspace) | Si (configuracion independiente) |
| Aislamiento de blast radius | Bajo (mismo state file) | Alto (state files completamente aislados) |
| Legibilidad del codigo | Baja (ternarios `var.env == "prod" ? 4 : 1`) | Alta (valores explícitos por entorno) |
| Soporte multi-cuenta AWS | Complejo | Nativo |
| Referencia oficial Gruntwork | N/A | [terragrunt.gruntwork.io](https://terragrunt.gruntwork.io) |

**Conclusion**: Workspaces son útiles para aislar state durante desarrollo, pero no escalan a arquitecturas enterprise con entornos que tienen configuraciones significativamente distintas. Terragrunt es la solución recomendada por Gruntwork, empresa fundada por los autores del libro "Terraform: Up & Running".

---

## Arquitectura del Lab v7

```
v7-enterprise-gitops/
├── .github/
│   └── workflows/
│       └── gitops.yml              <- Pipeline GitOps: plan en PR, apply en merge
├── terragrunt/
│   ├── terragrunt.hcl              <- Config raiz: backend + provider (DRY)
│   ├── _modules/                   <- Modulos Terraform reutilizables
│   │   ├── vpc/                    <- main.tf, variables.tf, outputs.tf
│   │   ├── ecs-cluster/            <- main.tf, variables.tf, outputs.tf
│   │   ├── alb/                    <- main.tf, variables.tf, outputs.tf
│   │   └── ecs-service/            <- main.tf, variables.tf, outputs.tf, autoscaling.tf
│   ├── dev/
│   │   ├── env.hcl                 <- Variables especificas de dev
│   │   ├── vpc/terragrunt.hcl
│   │   ├── alb/terragrunt.hcl
│   │   ├── ecs-cluster/terragrunt.hcl
│   │   └── ecs-service/terragrunt.hcl
│   ├── staging/
│   │   ├── env.hcl
│   │   └── ... (misma estructura que dev)
│   └── prod/
│       ├── env.hcl
│       └── ... (misma estructura que dev)
└── atmos/
    ├── atmos.yaml                  <- Config principal de Atmos
    ├── stacks/
    │   ├── _defaults.yaml          <- Variables compartidas entre todos los stacks
    │   ├── dev.yaml
    │   ├── staging.yaml
    │   └── prod.yaml
    ├── components/
    │   └── terraform/              <- Wrappers que referencian _modules/
    │       ├── vpc/
    │       ├── ecs-cluster/
    │       ├── alb/
    │       └── ecs-service/
    └── workflows/
        └── deploy.yaml             <- Workflows de Atmos (deploy-dev, deploy-prod, etc.)
```

### Estado de Terraform por entorno

```
s3://shopapi-terraform-state-{account_id}/
├── dev/
│   ├── vpc/terraform.tfstate
│   ├── alb/terraform.tfstate
│   ├── ecs-cluster/terraform.tfstate
│   └── ecs-service/terraform.tfstate
├── staging/
│   └── ...
└── prod/
    └── ...
```

Cada entorno tiene su propio state file, completamente aislado. Un `destroy` accidental en dev no afecta prod.

---

## Diferencias entre entornos

| Parametro | dev | staging | prod |
|-----------|-----|---------|------|
| Desired Count API | 1 | 2 | 4 |
| Desired Count Workers | 0 | 1 | 2 |
| Min tasks API | 1 | 1 | 2 |
| Max tasks API | 5 | 8 | 20 |
| Fargate Spot % | 80% | 75% | 25% |
| Multi-AZ | 1 AZ | 2 AZs | 3 AZs |
| Log retention | 7 dias | 30 dias | 90 dias |
| Container Insights | No | Si | Si |
| VPC CIDR | 10.1.0.0/16 | 10.2.0.0/16 | 10.0.0.0/16 |
| ALB deletion protection | No | No | Si |
| Scale-down nocturno | Si | No | No |

---

## Parte 1: Terragrunt

### Instalacion

```bash
# macOS
brew install terragrunt

# Linux (descarga directa)
TERRAGRUNT_VERSION="0.55.0"
wget "https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/terragrunt_linux_amd64"
chmod +x terragrunt_linux_amd64
sudo mv terragrunt_linux_amd64 /usr/local/bin/terragrunt

# Verificar instalacion
terragrunt --version
```

### Como funciona la herencia de configuracion

Terragrunt usa una jerarquía de archivos `terragrunt.hcl`. Cuando se ejecuta desde una carpeta hija, busca el archivo raiz con `find_in_parent_folders()`:

```
terragrunt/
├── terragrunt.hcl          <- RAIZ: define backend + provider
└── dev/
    ├── env.hcl             <- Variables del entorno
    └── ecs-service/
        └── terragrunt.hcl  <- include "root" hereda el backend y provider
                               include "env" lee las variables del entorno
```

El archivo de servicio (`ecs-service/terragrunt.hcl`) incluye la configuracion raiz, lo que hace que Terragrunt genere automaticamente `backend.tf` y `provider.tf` con los valores correctos para ese entorno.

### Root terragrunt.hcl: la clave del DRY

El archivo `terragrunt/terragrunt.hcl` es la configuracion raiz. Define:

1. **remote_state**: genera `backend.tf` automaticamente con la key correcta para cada modulo
2. **generate "provider"**: genera `provider.tf` con los tags por entorno

La key del estado es dinamica: `"${local.environment}/${path_relative_to_include()}/terraform.tfstate"`. Para `dev/ecs-service/`, `path_relative_to_include()` devuelve `dev/ecs-service`, resultando en `dev/dev/ecs-service/terraform.tfstate`.

### Estructura del modulo ecs-service

El modulo Terraform `_modules/ecs-service/` define la infraestructura reutilizable:

```
_modules/ecs-service/
├── main.tf         <- ECS Service, Task Definition, Security Groups
├── variables.tf    <- Inputs del modulo
├── outputs.tf      <- Outputs para otros modulos
└── autoscaling.tf  <- Application Auto Scaling
```

El archivo `dev/ecs-service/terragrunt.hcl` apunta al modulo y le pasa los valores del entorno:

```hcl
terraform {
  source = "../../../_modules//ecs-service"  # La doble barra es sintaxis Terragrunt
}
```

La doble barra `//` en el source indica a Terragrunt que todo lo que hay despues es la ruta dentro del modulo, permitiendo versionar modulos con Git tags: `git::https://github.com/org/infra-modules.git//ecs-service?ref=v1.2.0`.

### Dependencias entre modulos

Terragrunt maneja dependencias explícitas entre modulos. El modulo `ecs-service` depende de `vpc`, `ecs-cluster` y `alb`:

```hcl
dependency "vpc" {
  config_path = "../vpc"

  # mock_outputs se usa cuando se ejecuta plan sin que vpc exista
  # Permite planificar ecs-service de forma aislada
  mock_outputs = {
    private_subnet_ids = ["subnet-mock1", "subnet-mock2"]
    vpc_id             = "vpc-mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}
```

Los `mock_outputs` son cruciales para el flujo GitOps: permiten ejecutar `plan` en una PR incluso si la VPC no existe aun.

### Comandos Terragrunt

```bash
# --- Planificar un modulo individual ---
cd terragrunt/dev/ecs-service
terragrunt plan

# --- Planificar todo el stack dev (respeta el orden de dependencias) ---
cd terragrunt/dev
terragrunt run-all plan

# --- Aplicar solo el modulo de ECS Service ---
cd terragrunt/dev/ecs-service
terragrunt apply

# --- Aplicar todo el stack dev ---
cd terragrunt/dev
terragrunt run-all apply

# --- Ver el grafo de dependencias ---
cd terragrunt/dev
terragrunt graph-dependencies

# --- Ver el output de un modulo dependiente ---
cd terragrunt/dev/ecs-service
terragrunt output

# --- Inicializar sin aplicar (util en CI/CD) ---
cd terragrunt/dev
terragrunt run-all init

# --- Destruir todo el entorno dev (orden inverso de dependencias) ---
cd terragrunt/dev
terragrunt run-all destroy

# --- Ver que comandos se ejecutarian sin ejecutarlos (dry-run) ---
cd terragrunt/dev
terragrunt run-all plan --terragrunt-log-level debug 2>&1 | grep "Running command"
```

### Orden de despliegue respetado automaticamente

Cuando se ejecuta `terragrunt run-all apply` desde `dev/`, Terragrunt calcula el grafo de dependencias y aplica en orden:

```
1. vpc          (sin dependencias)
2. alb          (depende de vpc)
3. ecs-cluster  (depende de vpc)
4. ecs-service  (depende de vpc + alb + ecs-cluster)
```

Si `vpc` y `alb` no tienen dependencias entre si, Terragrunt los aplica en **paralelo** para reducir el tiempo total.

---

## Parte 2: Atmos

### Que es Atmos y por que complementa a Terragrunt

Atmos es una CLI open-source de Cloud Posse que añade una capa de orquestacion sobre Terraform/Terragrunt. Mientras Terragrunt resuelve el problema de la repeticion de configuracion, Atmos resuelve el problema de la orquestacion de stacks completos.

| Responsabilidad | Herramienta |
|-----------------|-------------|
| Eliminar repeticion de backend/provider | Terragrunt |
| Dependencias entre modulos | Terragrunt |
| Definicion declarativa de stacks completos | Atmos |
| Workflows de despliegue (deploy, destroy, validate) | Atmos |
| Validacion de stacks antes de aplicar | Atmos |
| Generacion de diagramas de arquitectura | Atmos |

**Analogia**: Terragrunt es como Helm para Kubernetes (gestiona dependencias y configuracion), y Atmos es como ArgoCD (orquesta despliegues completos).

Documentacion oficial: [atmos.tools](https://atmos.tools)

### Instalacion de Atmos

```bash
# macOS
brew install atmos

# Linux
ATMOS_VERSION="1.63.0"
wget "https://github.com/cloudposse/atmos/releases/download/v${ATMOS_VERSION}/atmos_linux_amd64"
chmod +x atmos_linux_amd64
sudo mv atmos_linux_amd64 /usr/local/bin/atmos

# Verificar
atmos version
```

### Estructura de Atmos: stacks + components

Atmos separa la **definicion** (stacks YAML) de la **implementacion** (components Terraform):

- **Stacks** (`stacks/dev.yaml`): declaran que componentes se despliegan y con que variables
- **Components** (`components/terraform/vpc/`): el codigo Terraform real

Esta separacion permite que el mismo componente `ecs-service` se use en dev, staging y prod con configuraciones distintas definidas en los YAML de stack.

### Componentes: wrappers sobre _modules/

Los componentes en `atmos/components/terraform/` son wrappers que referencian los mismos módulos Terraform de `terragrunt/_modules/`. Esto evita duplicar código — un único módulo es usado tanto por Terragrunt como por Atmos:

```
terragrunt/_modules/vpc/      <- Módulo Terraform real
        ↑                           ↑
terragrunt/dev/vpc/           atmos/components/terraform/vpc/
  (via source = "_modules//vpc")    (via module "vpc" { source = "_modules/vpc" })
```

En producción, los módulos estarían en un repositorio Git separado y ambas herramientas apuntarían a él por tag:
```hcl
# Terragrunt
source = "git::https://github.com/tu-org/infra-modules.git//vpc?ref=v1.2.0"

# Atmos component
module "vpc" {
  source = "git::https://github.com/tu-org/infra-modules.git//vpc?ref=v1.2.0"
}
```

### Paso con Atmos: actualizar Account ID en los stacks

A diferencia de Terragrunt (que usa `env.hcl`), Atmos toma las variables de los archivos YAML de stack. Antes de desplegar, actualizar `ACCOUNT_ID_PLACEHOLDER`:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed -i "s/ACCOUNT_ID_PLACEHOLDER/${ACCOUNT_ID}/g" \
  atmos/stacks/dev.yaml \
  atmos/stacks/staging.yaml \
  atmos/stacks/prod.yaml
```

### Comandos Atmos

```bash
# --- Planificar un componente en un stack ---
atmos terraform plan ecs-service -s dev
atmos terraform plan vpc -s staging

# --- Aplicar un componente en un stack ---
atmos terraform apply ecs-service -s prod

# --- Ver todos los stacks definidos ---
atmos describe stacks

# --- Ver la configuracion final de un componente en un stack ---
atmos describe component ecs-service -s dev

# --- Ejecutar un workflow completo ---
atmos workflow deploy -f workflows/deploy.yaml -w deploy-dev

# --- Validar la configuracion de todos los stacks ---
atmos validate stacks

# --- Ver el diff entre la configuracion actual y la desplegada ---
atmos terraform show ecs-service -s dev
```

### Ejemplo: flujo de despliegue completo con Atmos

```bash
# 1. Validar que todos los stacks tienen configuracion correcta
atmos validate stacks

# 2. Planificar todos los componentes del stack dev
atmos terraform plan vpc -s dev
atmos terraform plan ecs-cluster -s dev
atmos terraform plan ecs-service -s dev

# 3. Aplicar en orden usando el workflow
atmos workflow deploy -f workflows/deploy.yaml -w deploy-dev

# 4. Verificar que todo esta desplegado
atmos describe stacks --stack dev
```

---

## Parte 3: GitOps Completo

### Flujo GitOps

```
Developer                  GitHub                    AWS
    |                        |                         |
    |-- git push feature --> |                         |
    |                        |-- Trigger CI ---------->|
    |                        |   (lint + validate)     |
    |                        |                         |
    |-- Pull Request ------> |                         |
    |                        |-- terragrunt plan ------>|
    |                        |<-- Plan output ----------|
    |                        |-- Comentar plan en PR    |
    |                        |                         |
    |<-- Review plan --------|                         |
    |-- Aprobar PR --------> |                         |
    |                        |-- Merge a main           |
    |                        |-- terragrunt apply ----->|
    |                        |<-- Apply exitoso --------|
    |                        |-- Notificacion Slack     |
    |<-- Deploy completo ----|                         |
```

### Estrategia de promotion entre entornos

El despliegue sigue un modelo de **promotion progresiva**:

1. **PR a `dev`**: despliegue automatico en dev tras merge
2. **PR a `staging`**: requiere que tests en dev pasen + aprobacion manual
3. **PR a `main`**: requiere que tests en staging pasen + aprobacion de 2 reviewers

```
feature/* ---> dev ---> staging ---> main (prod)
              auto      manual       manual x2
```

### GitHub Actions vs Atlantis

| Caracteristica | GitHub Actions | Atlantis |
|----------------|---------------|----------|
| Configuracion | YAML en .github/workflows/ | atlantis.yaml en la raiz |
| Integracion PR | Nativa | Via webhook |
| Coste | Gratuito (public) / minutos (private) | Self-hosted (EC2, EKS) |
| Permisos AWS | OIDC o secrets | IAM role en el servidor |
| Comentarios en PR | Custom con script | Automaticos y formateados |
| Bloqueo de PR | Manual (status checks) | Automatico (lock en apply) |
| Curva de aprendizaje | Baja | Media |
| Recomendado para | Equipos que ya usan GH Actions | Equipos large-scale con muchos PRs |

Para este lab se usa **GitHub Actions** por su integracion nativa con GitHub y menor overhead operacional.

### Pipeline GitOps (`.github/workflows/gitops.yml`)

El pipeline implementa las siguientes etapas:

**En Pull Request:**
1. `terraform fmt -check`: verifica el formato del codigo
2. `terragrunt validate`: valida la sintaxis HCL
3. `terragrunt run-all plan`: genera el plan y lo guarda como artefacto
4. Comenta el plan en el PR usando la GitHub API
5. Establece el status check del PR

**En Merge a main:**
1. Detecta que entorno corresponde segun la rama destino
2. `terragrunt run-all apply --terragrunt-non-interactive`
3. Notifica el resultado en Slack

**Seguridad del pipeline:**
- Credenciales AWS via OIDC (sin access keys en secrets)
- Apply solo desde rama protegida `main`
- Required reviewers configurados en la rama
- Estado de Terraform bloqueado con DynamoDB durante el apply

---

## Guia paso a paso

### Prerequisitos

```bash
# Verificar versiones
terraform --version   # >= 1.6.0
terragrunt --version  # >= 0.55.0
atmos version         # >= 1.63.0
aws --version         # >= 2.0.0

# Configurar credenciales AWS
aws configure --profile shopapi-dev
aws configure --profile shopapi-prod

# Verificar acceso
aws sts get-caller-identity --profile shopapi-dev
```

### Paso 1: Crear la infraestructura base del estado

Antes de usar Terragrunt, el bucket S3 y la tabla DynamoDB para el estado deben existir. Esto se hace una sola vez:

```bash
# Sustituir con tu Account ID real
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Crear bucket S3 para el estado
aws s3api create-bucket \
  --bucket "shopapi-terraform-state-${ACCOUNT_ID}" \
  --region eu-west-1 \
  --create-bucket-configuration LocationConstraint=eu-west-1

# Habilitar versionado (permite rollback del estado)
aws s3api put-bucket-versioning \
  --bucket "shopapi-terraform-state-${ACCOUNT_ID}" \
  --versioning-configuration Status=Enabled

# Habilitar cifrado por defecto
aws s3api put-bucket-encryption \
  --bucket "shopapi-terraform-state-${ACCOUNT_ID}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

# Crear tabla DynamoDB para el lock
aws dynamodb create-table \
  --table-name shopapi-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region eu-west-1
```

### Paso 2: Actualizar el Account ID en env.hcl

```bash
# Obtener el Account ID actual
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account ID: ${ACCOUNT_ID}"

# Actualizar los env.hcl (sustituir ACCOUNT_ID_PLACEHOLDER)
sed -i "s/ACCOUNT_ID_PLACEHOLDER/${ACCOUNT_ID}/g" \
  terragrunt/dev/env.hcl \
  terragrunt/staging/env.hcl \
  terragrunt/prod/env.hcl
```

### Paso 3: Desplegar el entorno dev

```bash
# Navegar a la carpeta de dev
cd terragrunt/dev

# Inicializar todos los modulos
terragrunt run-all init

# Ver el plan completo (respeta el orden de dependencias)
terragrunt run-all plan

# Aplicar si el plan es correcto
terragrunt run-all apply
```

### Paso 4: Desplegar staging y prod

```bash
# Staging
cd terragrunt/staging
terragrunt run-all apply

# Produccion (pedir confirmacion explicita)
cd terragrunt/prod
terragrunt run-all plan
# Revisar el plan cuidadosamente antes de aplicar en prod
terragrunt run-all apply
```

---

## Troubleshooting Terragrunt

### Escenario 1: Error "Error finding parent terragrunt files"

**Sintoma:**
```
ERRO[0000] Error finding parent terragrunt files
ERRO[0000] Did not find any Terragrunt config files in parent directories of path: /home/user/dev/ecs-service
```

**Causa:** Se esta ejecutando Terragrunt desde una carpeta que no tiene `terragrunt.hcl` en la jerarquia de padres, o el `find_in_parent_folders()` no puede encontrar el archivo raiz.

**Solucion:**
```bash
# Verificar que el archivo raiz existe
ls terragrunt/terragrunt.hcl

# Verificar desde que directorio se esta ejecutando
pwd

# Si se ejecuta desde fuera de la estructura correcta, usar la flag
terragrunt plan --terragrunt-config /ruta/absoluta/a/terragrunt.hcl

# Habilitar el log detallado para ver que archivos busca
terragrunt plan --terragrunt-log-level debug 2>&1 | grep -i "finding parent"
```

### Escenario 2: Error de dependencia con mock_outputs

**Sintoma:**
```
ERRO[0000] Error reading outputs of module ../vpc: /tmp/.../vpc
Error: No outputs for module: vpc
  The module vpc has not been applied yet
```

**Causa:** Se esta ejecutando `plan` en `ecs-service` pero el modulo `vpc` todavia no ha sido aplicado, y los `mock_outputs` no estan configurados para el comando `plan`.

**Solucion:**
```hcl
# En dev/ecs-service/terragrunt.hcl, asegurarse de incluir el comando plan en mock_outputs_allowed
dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    private_subnet_ids = ["subnet-mock1", "subnet-mock2"]
    vpc_id             = "vpc-mock"
  }
  # IMPORTANTE: incluir "plan" en la lista
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}
```

```bash
# Alternativa: planificar toda la pila desde el nivel dev (Terragrunt resuelve el orden)
cd terragrunt/dev
terragrunt run-all plan  # usa los outputs reales si vpc ya existe
```

### Escenario 3: Lock de DynamoDB no liberado

**Sintoma:**
```
Error acquiring the state lock
Error message: ConditionalCheckFailedException: The conditional request failed
  Lock Info:
    ID:        abc123
    Path:      shopapi-terraform-state-123/dev/ecs-service/terraform.tfstate
    Operation: OperationTypeApply
    Who:       github-actions@runner-2
```

**Causa:** Un apply anterior fue interrumpido y no libero el lock de DynamoDB.

**Solucion:**
```bash
# Ver el lock activo
aws dynamodb get-item \
  --table-name shopapi-terraform-locks \
  --key '{"LockID": {"S": "shopapi-terraform-state-123/dev/ecs-service/terraform.tfstate"}}' \
  --region eu-west-1

# Liberar el lock manualmente (solo si se confirma que no hay apply en progreso)
cd terragrunt/dev/ecs-service
terragrunt force-unlock LOCK_ID

# O directamente con Terraform
terraform force-unlock LOCK_ID
```

---

## Limpieza de recursos

```bash
# --- Destruir un entorno completo ---
# ATENCION: Esto elimina todos los recursos del entorno

# Destruir dev (mas seguro para practicar)
cd terragrunt/dev
terragrunt run-all destroy

# Destruir staging
cd terragrunt/staging
terragrunt run-all destroy

# Destruir prod (requiere confirmacion explicita)
cd terragrunt/prod
terragrunt run-all destroy --terragrunt-parallelism 1  # Destruir de a uno por seguridad

# --- Limpiar el estado remoto (despues de destroy) ---
# Vaciar el bucket S3 antes de eliminarlo
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3 rm "s3://shopapi-terraform-state-${ACCOUNT_ID}" --recursive

# Eliminar el bucket
aws s3api delete-bucket \
  --bucket "shopapi-terraform-state-${ACCOUNT_ID}" \
  --region eu-west-1

# Eliminar la tabla DynamoDB
aws dynamodb delete-table \
  --table-name shopapi-terraform-locks \
  --region eu-west-1
```

---

## Referencias

- [Terragrunt: documentacion oficial de Gruntwork](https://terragrunt.gruntwork.io)
- [Atmos: documentacion oficial de Cloud Posse](https://atmos.tools)
- [Terraform: Up & Running (libro de referencia)](https://www.terraformupandrunning.com)
- [Atlantis: alternativa a GitHub Actions para Terraform](https://www.runatlantis.io)
- [OIDC con GitHub Actions y AWS](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- [AWS Fargate Spot: documentacion oficial](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/fargate-capacity-providers.html)
