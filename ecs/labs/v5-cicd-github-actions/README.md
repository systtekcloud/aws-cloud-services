# Lab v5 — CI/CD con GitHub Actions, OIDC y ECS

**Proyecto**: ShopAPI | **Región**: eu-west-1 | **Nivel**: Intermedio-Avanzado
**Tiempo estimado**: 3-4 horas | **Coste estimado**: < 0.50 USD

---

## Objetivo

Eliminar los despliegues manuales implementando un pipeline GitOps completo:

- Cada push activa tests automáticos y construye la imagen Docker
- Cada merge a `main` despliega automáticamente en ECS sin necesidad de acceso directo a AWS
- Credenciales efímeras con OIDC (sin access keys estáticas en GitHub)
- Entornos separados (`dev` y `prod`) con aprobación manual para producción
- Introducción a Terragrunt para gestionar infraestructura multi-entorno

---

## Arquitectura del Pipeline

```
┌─────────────────────────────────────────────────────────────────┐
│                        DESARROLLADOR                           │
│                                                                 │
│   git push feature/xxx          git merge main                  │
└──────────────┬──────────────────────────┬───────────────────────┘
               │                          │
               ▼                          ▼
┌─────────────────────────┐  ┌────────────────────────────────────┐
│   GitHub Actions: CI    │  │      GitHub Actions: CD            │
│                         │  │                                    │
│  1. Checkout código     │  │  1. OIDC → AssumeRole AWS          │
│  2. Lint (flake8)       │  │  2. Login ECR                      │
│  3. Test (pytest)       │  │  3. Descargar task definition      │
│  4. Build Docker image  │  │  4. Render nueva task def (SHA)    │
│  5. Push ECR            │  │  5. Update ECS service             │
│     - tag: SHA          │  │  6. Wait for stability             │
│     - tag: latest       │  │                                    │
└─────────────────────────┘  │  Job deploy-dev: automático        │
                              │  Job deploy-prod: aprobación manual│
                              └──────────────────┬─────────────────┘
                                                 │
                                                 ▼
                              ┌──────────────────────────────────┐
                              │         ECS Rolling Update        │
                              │                                   │
                              │  Nuevas tasks → RUNNING          │
                              │  Tasks antiguas → DRAINING        │
                              │  ALB → tráfico a nuevas tasks    │
                              └──────────────────────────────────┘
```

### Flujo de autenticación OIDC

```
GitHub Actions Runner
       │
       │  1. Solicita JWT token al endpoint OIDC de GitHub
       ▼
GitHub OIDC Provider (token.actions.githubusercontent.com)
       │
       │  2. Emite JWT firmado con claims:
       │     - sub: repo:TU_USUARIO/shopapi:ref:refs/heads/main
       │     - aud: sts.amazonaws.com
       │     - iss: https://token.actions.githubusercontent.com
       ▼
AWS STS (AssumeRoleWithWebIdentity)
       │
       │  3. Valida JWT contra OIDC Provider registrado en IAM
       │  4. Verifica trust policy (repo correcto, rama correcta)
       │  5. Emite credenciales temporales (15 min - 1 hora)
       ▼
GitHub Actions Runner (credenciales efímeras)
       │
       │  6. Usa credenciales para: ECR push, ECS deploy
       ▼
ECR / ECS
```

---

## Prerrequisitos

- Lab v4 completado (ECS Service con AutoScaling funcionando)
- Cuenta de GitHub con repositorio `shopapi`
- GitHub CLI instalado: `gh --version`
- AWS CLI configurado con permisos de administrador
- Terraform >= 1.5 instalado
- Docker instalado y en ejecución

### Verificar prerrequisitos

```bash
# GitHub CLI
gh --version
gh auth status

# AWS CLI
aws sts get-caller-identity

# Terraform
terraform version

# Docker
docker info
```

---

## Fase A1 — OIDC Provider (sin access keys)

### ¿Por qué OIDC en lugar de access keys?

| Característica | Access Keys estáticas | OIDC (Recomendado) |
|---|---|---|
| Duración | Permanentes hasta rotación manual | 15 min - 1 hora (efímeras) |
| Almacenamiento | Secret en GitHub (encriptado) | No se almacenan credenciales |
| Rotación | Manual, propenso a olvidos | Automática en cada ejecución |
| Superficie de ataque | Si se filtran, acceso permanente | Si se filtran, expiran solas |
| Auditoría | Difícil distinguir origen | CloudTrail muestra el repo exacto |
| Coste | Gratis | Gratis |

**OIDC (OpenID Connect)** es un protocolo de identidad sobre OAuth 2.0. GitHub actúa como Identity Provider (IdP): firma JWTs que AWS verifica. Sin secretos en reposo.

### A1.1 — Crear OIDC Provider en IAM

**Opción A: Con Terraform (recomendado, ver Fase A5)**

```bash
cd terraform/
terraform init
terraform apply
```

**Opción B: Con AWS CLI**

```bash
# Obtener el thumbprint del certificado TLS de GitHub OIDC
# (GitHub publica su OIDC en https://token.actions.githubusercontent.com)
THUMBPRINT=$(curl -s https://token.actions.githubusercontent.com/.well-known/openid-configuration \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['jwks_uri'])" \
  | xargs -I{} curl -sv {} 2>&1 \
  | grep -oP '(?<=SHA-256::)[A-Fa-f0-9]{64}' | tail -1 | tr '[:upper:]' '[:lower:]')

# Crear el OIDC Provider
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list "$THUMBPRINT"
```

> **Nota importante**: AWS ahora verifica automáticamente los certificados de GitHub OIDC, por lo que el thumbprint es menos crítico, pero sigue siendo requerido por la API. Puedes usar el thumbprint conocido de GitHub: `6938fd4d98bab03faadb97b34396831e3780aea`.

**Opción C: Desde la consola AWS**

1. IAM → Identity providers → Add provider
2. Provider type: OpenID Connect
3. Provider URL: `https://token.actions.githubusercontent.com`
4. Audience: `sts.amazonaws.com`
5. Add provider

### A1.2 — Crear IAM Role con Trust Policy OIDC

La **trust policy** es el elemento más importante de seguridad: define exactamente qué workflows de GitHub pueden asumir este rol.

#### Trust Policy completa

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::CUENTA_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:TU_USUARIO/shopapi:*"
        }
      }
    }
  ]
}
```

#### Anatomía del claim `sub` en GitHub Actions OIDC

El campo `sub` (subject) del JWT identifica de forma única el origen del workflow:

```
repo:{organización_o_usuario}/{repositorio}:{contexto}
```

Ejemplos de valores `sub`:

| Contexto | Valor del claim `sub` |
|---|---|
| Push a rama main | `repo:TU_USUARIO/shopapi:ref:refs/heads/main` |
| Push a cualquier rama | `repo:TU_USUARIO/shopapi:ref:refs/heads/*` |
| Pull Request | `repo:TU_USUARIO/shopapi:pull_request` |
| Environment "prod" | `repo:TU_USUARIO/shopapi:environment:prod` |
| Cualquier evento | `repo:TU_USUARIO/shopapi:*` |

> **Examen AWS**: La condición `StringLike` permite wildcards (`*`), mientras que `StringEquals` requiere coincidencia exacta. Para mayor seguridad en producción, usa `StringEquals` con el environment específico:
> ```json
> "StringEquals": {
>   "token.actions.githubusercontent.com:sub": "repo:TU_USUARIO/shopapi:environment:prod"
> }
> ```

#### Crear el rol con AWS CLI

```bash
# Guardar trust policy
cat > /tmp/trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::CUENTA_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:TU_USUARIO/shopapi:*"
        }
      }
    }
  ]
}
EOF

# Sustituir CUENTA_ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed -i "s/CUENTA_ID/$ACCOUNT_ID/g" /tmp/trust-policy.json

# Crear el rol
aws iam create-role \
  --role-name shopapi-github-actions-role \
  --assume-role-policy-document file:///tmp/trust-policy.json \
  --description "Rol para GitHub Actions CI/CD de ShopAPI via OIDC"
```

### A1.3 — Políticas de permisos del rol

El rol necesita permisos mínimos para realizar el pipeline. Principio de mínimo privilegio.

```bash
# Política inline con permisos necesarios
cat > /tmp/github-actions-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECRPush",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeRepositories",
        "ecr:ListImages"
      ],
      "Resource": "arn:aws:ecr:eu-west-1:CUENTA_ID:repository/shopapi/*"
    },
    {
      "Sid": "ECSDescribe",
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeServices",
        "ecs:DescribeTaskDefinition",
        "ecs:DescribeTasks",
        "ecs:ListTasks"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECSUpdateService",
      "Effect": "Allow",
      "Action": [
        "ecs:UpdateService"
      ],
      "Resource": "arn:aws:ecs:eu-west-1:CUENTA_ID:service/shopapi-cluster/shopapi-api"
    },
    {
      "Sid": "ECSRegisterTaskDef",
      "Effect": "Allow",
      "Action": [
        "ecs:RegisterTaskDefinition"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMPassRole",
      "Effect": "Allow",
      "Action": [
        "iam:PassRole"
      ],
      "Resource": [
        "arn:aws:iam::CUENTA_ID:role/shopapi-task-execution-role",
        "arn:aws:iam::CUENTA_ID:role/shopapi-task-role"
      ]
    }
  ]
}
EOF

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed -i "s/CUENTA_ID/$ACCOUNT_ID/g" /tmp/github-actions-policy.json

# Adjuntar política al rol
aws iam put-role-policy \
  --role-name shopapi-github-actions-role \
  --policy-name shopapi-github-actions-policy \
  --policy-document file:///tmp/github-actions-policy.json

# Verificar
aws iam get-role --role-name shopapi-github-actions-role
echo "ARN del rol:"
aws iam get-role --role-name shopapi-github-actions-role \
  --query 'Role.Arn' --output text
```

---

## Fase A2 — Configurar el Repositorio GitHub

### A2.1 — Inicializar repositorio con la estructura del proyecto

```bash
# Si no tienes el repositorio creado aún
gh repo create shopapi --public --description "ShopAPI — FastAPI en ECS Fargate"
cd /ruta/a/tu/proyecto
git remote add origin https://github.com/TU_USUARIO/shopapi.git

# Estructura mínima requerida
mkdir -p app/tests .github/workflows
```

### A2.2 — Crear secretos en GitHub

Los secretos son variables encriptadas accesibles en los workflows. Con OIDC, solo necesitamos el ID de cuenta y región (no las keys).

```bash
# Autenticarse con GitHub CLI
gh auth login

# Obtener el Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_ARN=$(aws iam get-role --role-name shopapi-github-actions-role \
  --query 'Role.Arn' --output text)

# Crear secretos en el repositorio
gh secret set AWS_ACCOUNT_ID --body "$ACCOUNT_ID" --repo TU_USUARIO/shopapi
gh secret set AWS_REGION --body "eu-west-1" --repo TU_USUARIO/shopapi

# Verificar secretos creados
gh secret list --repo TU_USUARIO/shopapi
```

### A2.3 — Crear Environments con protection rules

Los **Environments** de GitHub permiten:
- Variables y secretos específicos por entorno
- Reglas de protección (aprobación manual, rama requerida)
- Historial de despliegues por entorno

```bash
# Crear environment "dev" (sin restricciones, deploy automático)
gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  /repos/TU_USUARIO/shopapi/environments/dev

# Crear environment "prod" con protección
gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  /repos/TU_USUARIO/shopapi/environments/prod \
  -f wait_timer=0 \
  -F prevent_self_review=false \
  -f deployment_branch_policy=null
```

**Configurar aprobación manual para prod desde la consola GitHub:**

1. Ir a: Repositorio → Settings → Environments → prod
2. Activar: "Required reviewers"
3. Añadir tu usuario como revisor requerido
4. Guardar

> **Alternativa con API** (requiere GitHub Apps token con permisos admin):
> ```bash
> gh api \
>   --method PUT \
>   /repos/TU_USUARIO/shopapi/environments/prod \
>   --input - << 'EOF'
> {
>   "reviewers": [
>     {"type": "User", "id": TU_USER_ID}
>   ],
>   "deployment_branch_policy": {
>     "protected_branches": false,
>     "custom_branch_policies": true
>   }
> }
> EOF
> ```

### A2.4 — Variables de entorno por environment

```bash
# Variables para dev
gh api \
  --method POST \
  /repos/TU_USUARIO/shopapi/environments/dev/variables \
  -f name='APP_ENV' -f value='development'

# Variables para prod
gh api \
  --method POST \
  /repos/TU_USUARIO/shopapi/environments/prod/variables \
  -f name='APP_ENV' -f value='production'
```

---

## Fase A3 — CI Workflow: Lint, Test, Build y Push

El workflow de CI se encuentra en `.github/workflows/ci.yml`. Se activa en cada push y PR.

### Estructura del job `test`

```
trigger: push o pull_request
   │
   ├── job: test
   │     ├── checkout código
   │     ├── setup Python 3.12
   │     ├── pip install (requirements + pytest + httpx)
   │     └── pytest app/tests/ -v
   │
   └── job: build-push (necesita: test, solo en push)
         ├── checkout código
         ├── Configure AWS (OIDC) ← credenciales efímeras
         ├── Login ECR
         ├── Build imagen Docker
         ├── Tag: SHA corto + latest
         └── Push ambas tags a ECR
```

### Tags de imagen y trazabilidad

Usamos dos tags simultáneas:

| Tag | Ejemplo | Uso |
|---|---|---|
| SHA del commit | `abc1234def5678...` | Inmutable, trazabilidad exacta |
| `latest` | `latest` | Referencia mutable para desarrollo |

El tag SHA es el que se usa en producción: permite saber exactamente qué código está desplegado y hacer rollbacks precisos.

### Acciones de GitHub utilizadas

| Acción | Versión | Propósito |
|---|---|---|
| `actions/checkout` | v4 | Descargar código del repo |
| `actions/setup-python` | v5 | Instalar Python en el runner |
| `aws-actions/configure-aws-credentials` | v4 | Autenticar con AWS via OIDC |
| `aws-actions/amazon-ecr-login` | v2 | Login en ECR, obtener registry URL |
| `docker/build-push-action` | v5 | Build y push optimizado (caché de capas) |

### Permiso `id-token: write`

Este permiso es **obligatorio** para OIDC. Permite al runner de GitHub solicitar un JWT token al endpoint OIDC de GitHub:

```yaml
permissions:
  id-token: write   # Permite solicitar JWT para OIDC
  contents: read    # Permite checkout del código
```

Sin `id-token: write`, el paso de `configure-aws-credentials` falla con:
```
Error: Credentials could not be loaded, please check your action inputs:
Could not load credentials from any providers
```

---

## Fase A4 — CD Workflow: Deploy a ECS

El workflow de CD se encuentra en `.github/workflows/deploy.yml`. Se activa solo en merges a `main`.

### Flujo del job deploy-dev

```
push a main
   │
   └── deploy-dev (environment: dev, automático)
         ├── Configure AWS (OIDC)
         ├── Login ECR
         ├── Descargar task definition actual de ECS
         │     aws ecs describe-task-definition → task-definition.json
         ├── Render nueva task definition
         │     Reemplaza la imagen con nueva SHA
         │     Añade variables de entorno (APP_ENV, APP_VERSION)
         ├── Register + Deploy nueva task definition
         │     aws ecs register-task-definition (nueva revisión)
         │     aws ecs update-service (apunta a nueva revisión)
         └── Wait for service stability (timeout: 10 min)
               Espera a que todas las tasks nuevas estén RUNNING
               y las antiguas DRAINED
```

### Flujo del job deploy-prod

```
deploy-prod (environment: prod, necesita: deploy-dev)
   │
   ├── [Pausa] → GitHub solicita aprobación a reviewers configurados
   │              Reviewers reciben notificación por email
   │              Tienen que aprobar en GitHub UI o con gh CLI
   │
   └── [Aprobado] → mismo proceso que deploy-dev
                     pero con APP_ENV=production
```

### Acción `amazon-ecs-render-task-definition`

Esta acción modifica el JSON de la task definition para actualizar la imagen del contenedor sin tocar el resto de la configuración (secrets, volumes, network mode, etc.):

```yaml
- name: Render nueva task definition
  id: render
  uses: aws-actions/amazon-ecs-render-task-definition@v1
  with:
    task-definition: task-definition.json   # JSON descargado de ECS
    container-name: shopapi-api             # Nombre del contenedor a actualizar
    image: 123456789.dkr.ecr.eu-west-1.amazonaws.com/shopapi/api:abc1234
    environment-variables: |               # Variables adicionales (KEY=VALUE)
      APP_ENV=dev
      APP_VERSION=abc1234
```

### Acción `amazon-ecs-deploy-task-definition`

Registra la task definition modificada como nueva revisión y actualiza el service:

```yaml
- name: Deploy ECS service
  uses: aws-actions/amazon-ecs-deploy-task-definition@v1
  with:
    task-definition: ${{ steps.render.outputs.task-definition }}
    service: shopapi-api
    cluster: shopapi-cluster
    wait-for-service-stability: true   # Espera hasta que el rolling update complete
```

---

## Fase A5 — Introducción a Terragrunt

### ¿Por qué Terragrunt?

Con Terraform puro para múltiples entornos, el problema es la repetición:

```
# Sin Terragrunt: repetir provider, backend, módulo en cada entorno
terraform/
  dev/
    main.tf      ← copia de prod/main.tf con variables diferentes
    variables.tf ← casi idéntico
    backend.tf   ← diferente bucket/key
  prod/
    main.tf      ← copia de dev/main.tf
    variables.tf ← casi idéntico
    backend.tf   ← diferente bucket/key
```

**Terragrunt** resuelve esto con DRY (Don't Repeat Yourself):

```
# Con Terragrunt: un módulo reutilizado por todos los entornos
terraform/
  modules/
    cicd-oidc/
      main.tf       ← definición una sola vez
      variables.tf
  environments/
    dev/
      terragrunt.hcl  ← solo valores específicos de dev
    prod/
      terragrunt.hcl  ← solo valores específicos de prod
  terragrunt.hcl    ← configuración común (provider, backend)
```

### Instalar Terragrunt

```bash
# Linux/macOS
TERRAGRUNT_VERSION=$(curl -s https://api.github.com/repos/gruntwork-io/terragrunt/releases/latest \
  | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')

curl -Lo /usr/local/bin/terragrunt \
  "https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/terragrunt_linux_amd64"

chmod +x /usr/local/bin/terragrunt
terragrunt --version
```

### Estructura de carpetas para ShopAPI

```
shopapi-infra/
├── terragrunt.hcl                   # Configuración raíz: provider, backend S3
├── modules/
│   ├── cicd-oidc/                   # Módulo OIDC (lo que tienes en terraform/)
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── ecs-service/                 # Módulo ECS (del lab v2-v4)
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
└── environments/
    ├── dev/
    │   ├── terragrunt.hcl           # Incluye módulo, pasa variables de dev
    │   └── cicd-oidc/
    │       └── terragrunt.hcl
    └── prod/
        ├── terragrunt.hcl           # Incluye módulo, pasa variables de prod
        └── cicd-oidc/
            └── terragrunt.hcl
```

### terragrunt.hcl raíz (configuración común)

```hcl
# terragrunt.hcl (raíz del proyecto)
locals {
  aws_region  = "eu-west-1"
  project     = "shopapi"
  environment = basename(dirname(get_terragrunt_dir()))
}

# Backend remoto: S3 + DynamoDB para state locking
remote_state {
  backend = "s3"
  config = {
    bucket         = "${local.project}-terraform-state-${get_aws_account_id()}"
    key            = "${local.environment}/${path_relative_to_include()}/terraform.tfstate"
    region         = local.aws_region
    encrypt        = true
    dynamodb_table = "${local.project}-terraform-locks"
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}

# Provider AWS generado automáticamente
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = "${local.aws_region}"
  default_tags {
    tags = {
      Project     = "${local.project}"
      Environment = "${local.environment}"
      ManagedBy   = "Terragrunt"
    }
  }
}
EOF
}
```

### terragrunt.hcl por entorno (ejemplo dev/cicd-oidc)

```hcl
# environments/dev/cicd-oidc/terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules//cicd-oidc"
}

inputs = {
  github_org    = "TU_USUARIO"
  github_repo   = "shopapi"
  aws_region    = "eu-west-1"
  environment   = "dev"
}
```

### Primeros comandos Terragrunt

```bash
# Inicializar (equivale a terraform init)
cd environments/dev/cicd-oidc
terragrunt init

# Plan
terragrunt plan

# Apply
terragrunt apply

# Todos los entornos a la vez (desde la raíz)
terragrunt run-all plan
terragrunt run-all apply

# Destruir un entorno específico
cd environments/dev/cicd-oidc
terragrunt destroy
```

---

## Validación del Pipeline Completo

### 1. Hacer un cambio y push

```bash
# Modificar algo en la app
echo "# cambio de prueba" >> app/main.py

git add app/main.py
git commit -m "test: verificar pipeline CI/CD"
git push origin main
```

### 2. Observar el CI en GitHub

```bash
# Ver los workflows en ejecución
gh run list --repo TU_USUARIO/shopapi

# Ver logs en tiempo real
gh run watch --repo TU_USUARIO/shopapi

# Ver detalle de un run específico
gh run view RUN_ID --log
```

### 3. Verificar la imagen en ECR

```bash
# Listar imágenes en ECR
aws ecr describe-images \
  --repository-name shopapi/api \
  --region eu-west-1 \
  --query 'sort_by(imageDetails, &imagePushedAt)[-3:].[imageTags[0], imagePushedAt]' \
  --output table
```

### 4. Verificar el deploy en ECS

```bash
# Estado del servicio
aws ecs describe-services \
  --cluster shopapi-cluster \
  --services shopapi-api \
  --query 'services[0].{Status:status, Running:runningCount, Desired:desiredCount, Pending:pendingCount}' \
  --output table

# Eventos del servicio (rolling update)
aws ecs describe-services \
  --cluster shopapi-cluster \
  --services shopapi-api \
  --query 'services[0].events[0:5]' \
  --output table

# Verificar la imagen que está corriendo
aws ecs describe-tasks \
  --cluster shopapi-cluster \
  --tasks $(aws ecs list-tasks --cluster shopapi-cluster --service-name shopapi-api \
    --query 'taskArns[0]' --output text) \
  --query 'tasks[0].containers[0].image' \
  --output text
```

### 5. Aprobar deploy a prod

```bash
# Ver deployments pendientes de aprobación
gh run list --repo TU_USUARIO/shopapi --status waiting

# Aprobar desde CLI
gh run approve RUN_ID

# O desde la interfaz web: Actions → run → Review deployments → Approve
```

---

## Troubleshooting

### Escenario 1: OIDC falla — "Not authorized to perform sts:AssumeRoleWithWebIdentity"

**Error en el workflow:**
```
Error: Not authorized to perform sts:AssumeRoleWithWebIdentity
```

**Causas y soluciones:**

**Causa A: Trust policy con repo incorrecto**
```bash
# Verificar la trust policy actual del rol
aws iam get-role \
  --role-name shopapi-github-actions-role \
  --query 'Role.AssumeRolePolicyDocument'

# El campo sub debe coincidir con: repo:TU_USUARIO/shopapi:*
# NO con: repo:TU_ORGANIZACION/shopapi:* si usas cuenta personal
```

**Causa B: OIDC Provider no creado o con URL incorrecta**
```bash
# Verificar OIDC providers registrados
aws iam list-open-id-connect-providers

# Verificar que el URL es exactamente:
# https://token.actions.githubusercontent.com (sin barra final)
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::CUENTA:oidc-provider/token.actions.githubusercontent.com
```

**Causa C: Falta el permiso `id-token: write` en el workflow**
```yaml
# Verificar que el job tiene:
permissions:
  id-token: write
  contents: read
```

**Causa D: El `audience` no es `sts.amazonaws.com`**
```bash
# En configure-aws-credentials, el audience por defecto es sts.amazonaws.com
# Si lo has cambiado, debe coincidir con el ClientID del OIDC Provider
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::CUENTA:oidc-provider/token.actions.githubusercontent.com \
  --query 'ClientIDList'
```

**Depuración avanzada: decodificar el JWT de GitHub**
```bash
# En el workflow, antes del configure-aws-credentials:
- name: Debug OIDC token
  run: |
    TOKEN=$(curl -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
      "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r '.value')
    # Decodificar payload (Base64URL)
    echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
```

---

### Escenario 2: CD falla en "wait for deployment" — Timeout / Circuit Breaker

**Error en el workflow:**
```
Error: Service shopapi-api deployment circuit breaker tripped
# o
Error: Timeout waiting for ECS service to stabilize
```

**Causa A: La nueva task falla al arrancar (health check)**
```bash
# Ver eventos del servicio
aws ecs describe-services \
  --cluster shopapi-cluster \
  --services shopapi-api \
  --query 'services[0].events[0:10]' \
  --output text

# Buscar tasks que hayan fallado (STOPPED)
aws ecs list-tasks \
  --cluster shopapi-cluster \
  --service-name shopapi-api \
  --desired-status STOPPED \
  --query 'taskArns' --output text

# Ver logs de la task fallida
TASK_ARN=$(aws ecs list-tasks --cluster shopapi-cluster \
  --service-name shopapi-api --desired-status STOPPED \
  --query 'taskArns[0]' --output text)

# Obtener el motivo de parada
aws ecs describe-tasks \
  --cluster shopapi-cluster \
  --tasks $TASK_ARN \
  --query 'tasks[0].{StopCode:stopCode, StopReason:stoppedReason, Containers:containers[0].{Reason:reason, ExitCode:exitCode}}' \
  --output json
```

**Causa B: Circuit breaker de ECS activado**
```bash
# Verificar la configuración de deployment circuit breaker del servicio
aws ecs describe-services \
  --cluster shopapi-cluster \
  --services shopapi-api \
  --query 'services[0].deploymentConfiguration'

# Si el circuit breaker está activo y hay rollback automático, el deployment
# anterior se restaura. Ver en eventos:
aws ecs describe-services \
  --cluster shopapi-cluster \
  --services shopapi-api \
  --query 'services[0].events' \
  --output text | grep -i "circuit\|rollback"
```

**Causa C: Timeout del workflow de GitHub Actions**
```yaml
# Aumentar el timeout del step de deploy (por defecto: 10 min en la action)
- name: Deploy ECS service
  uses: aws-actions/amazon-ecs-deploy-task-definition@v1
  timeout-minutes: 20  # Aumentar si el rolling update tarda más
  with:
    task-definition: ${{ steps.render.outputs.task-definition }}
    service: ${{ env.ECS_SERVICE }}
    cluster: ${{ env.ECS_CLUSTER }}
    wait-for-service-stability: true
    wait-for-minutes: 20  # Timeout de la action misma
```

**Rollback manual de emergencia:**
```bash
# Ver revisiones disponibles
aws ecs list-task-definitions \
  --family-prefix shopapi-api \
  --sort DESC \
  --query 'taskDefinitionArns[0:5]' \
  --output text

# Rollback a la revisión anterior
PREVIOUS_REVISION=$(aws ecs list-task-definitions \
  --family-prefix shopapi-api \
  --sort DESC \
  --query 'taskDefinitionArns[1]' \
  --output text)

aws ecs update-service \
  --cluster shopapi-cluster \
  --service shopapi-api \
  --task-definition $PREVIOUS_REVISION \
  --force-new-deployment
```

---

## Limpieza de Recursos

Eliminar los recursos creados en este lab para evitar costes:

```bash
# 1. Eliminar el IAM Role y sus políticas
aws iam delete-role-policy \
  --role-name shopapi-github-actions-role \
  --policy-name shopapi-github-actions-policy

aws iam delete-role \
  --role-name shopapi-github-actions-role

# 2. Obtener ARN del OIDC Provider
OIDC_ARN=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?ends_with(Arn, 'token.actions.githubusercontent.com')].Arn" \
  --output text)

# 3. Eliminar OIDC Provider
aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn "$OIDC_ARN"

# 4. Verificar eliminación
aws iam list-open-id-connect-providers
aws iam get-role --role-name shopapi-github-actions-role 2>&1 | grep -i "cannot be found"

# 5. Eliminar secretos de GitHub (opcional)
gh secret delete AWS_ACCOUNT_ID --repo TU_USUARIO/shopapi
gh secret delete AWS_REGION --repo TU_USUARIO/shopapi

# 6. Si usaste Terraform/Terragrunt
# cd terraform && terraform destroy
# cd environments/dev/cicd-oidc && terragrunt destroy
```

---

## Conceptos Clave para el Examen AWS SAA

| Concepto | Detalle |
|---|---|
| **OIDC Federation** | Permite a identidades externas (GitHub, GitLab, k8s) asumir roles IAM sin credenciales estáticas |
| **AssumeRoleWithWebIdentity** | API de STS para asumir un rol usando un JWT de un OIDC provider |
| **Trust Policy** | Quién puede asumir el rol. La condition `StringLike` con `sub` claim controla qué repo/rama |
| **Credenciales efímeras** | Las credenciales devueltas por STS expiran automáticamente (15min-12h). Más seguras que access keys |
| **ECS Rolling Update** | Estrategia de deployment por defecto. Reemplaza tasks gradualmente manteniendo disponibilidad |
| **ECS Circuit Breaker** | Detecta deployments fallidos y hace rollback automático |
| **ECR** | Registro de imágenes Docker totalmente gestionado. Integrado con IAM para autenticación |
| **GitHub Environments** | Permiten separar secretos/variables y añadir gates de aprobación manual al pipeline |

---

## Recursos Adicionales

- [GitHub OIDC documentation](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect)
- [AWS: Creating OIDC identity providers](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html)
- [aws-actions/configure-aws-credentials](https://github.com/aws-actions/configure-aws-credentials)
- [aws-actions/amazon-ecs-deploy-task-definition](https://github.com/aws-actions/amazon-ecs-deploy-task-definition)
- [Terragrunt documentation](https://terragrunt.gruntwork.io/docs/)

---

*Lab v5 de 7 — ShopAPI en ECS Fargate | AWS Solutions Architect Associate*
