# ShopAPI — Laboratorio Progresivo ECS (SA Associate)

> **Proyecto**: ShopAPI — API REST de catálogo eCommerce desplegada en Amazon ECS Fargate.
> **Objetivo**: Aprender ECS de forma práctica y construir un portfolio técnico real.
> **Examen target**: AWS Solutions Architect Associate.

---

## La historia del proyecto

Partimos de un container corriendo en local y lo llevamos hasta una arquitectura enterprise multi-AZ con CI/CD, GitOps y optimización de costes.

```
v1  → Container en ECR + RunTask manual
v2  → ECS Service + ALB + VPC privada
v3  → Secrets Manager + CloudWatch + IAM
v4  → AutoScaling Multi-AZ + Fargate Spot
v5  → CI/CD con GitHub Actions (GitOps)
v6  → Cost Optimization (VPC Endpoints, Capacity Providers)
v7  → Enterprise: Terragrunt + Atmos + multi-entorno
```

---

## Evolución de la arquitectura

```
v1: Container manual
    [Docker build] → [ECR] → [ECS RunTask]

v2: Servicio con load balancing
    [Internet] → [ALB] → [ECS Service] → [RDS/simulado]
                          (Private Subnet)

v3: Seguridad y observabilidad
    [Internet] → [ALB] → [ECS Service] → [Secrets Manager]
                                         [CloudWatch Logs]
                                         [X-Ray]

v4: Alta disponibilidad y escalado
    [Internet] → [ALB Multi-AZ] → [ECS AZ-a] [ECS AZ-b] [ECS AZ-c]
                                  [Workers Spot] ← [SQS Queue]

v5: CI/CD automático
    [GitHub Push] → [GitHub Actions] → [ECR] → [ECS Rolling Update]

v6: Costes optimizados
    + VPC Endpoints (sin NAT para ECR/Logs/Secrets)
    + FARGATE_SPOT para workers (70% ahorro)
    + Capacity Provider strategy

v7: Enterprise GitOps
    [PR merge] → [Terraform Plan CI] → [Approval] → [Terraform Apply]
    Terragrunt + Atmos + environments dev/staging/prod
```

---

## Tabla de progresión

| Lab | Tema principal | Herramientas | Nivel | Tiempo estimado |
|-----|---------------|-------------|-------|----------------|
| [v1](./v1-primer-container/) | ECR + primer container Fargate | Console + CLI + Terraform básico | ⭐ Básico | 45 min |
| [v2](./v2-servicio-alb/) | ECS Service + ALB + VPC privada | CLI + Terraform (vars/outputs) | ⭐⭐ Intermedio | 60 min |
| [v3](./v3-secrets-observabilidad/) | Secrets + IAM + CloudWatch | CLI + Terraform (módulos) | ⭐⭐ Intermedio | 75 min |
| [v4](./v4-autoscaling-multiz/) | AutoScaling + Multi-AZ + SQS | CLI + Terraform | ⭐⭐⭐ Avanzado | 90 min |
| [v5](./v5-cicd-github-actions/) | GitHub Actions → ECR → ECS | GitHub Actions + Terragrunt | ⭐⭐⭐ Avanzado | 90 min |
| [v6](./v6-cost-optimization/) | VPC Endpoints + Capacity Providers | Terraform + análisis de costes | ⭐⭐⭐ Avanzado | 60 min |
| [v7](./v7-enterprise-gitops/) | GitOps enterprise: Terragrunt + Atmos | Terragrunt + Atmos + GitHub | ⭐⭐⭐⭐ Expert | 120 min |

---

## La aplicación: ShopAPI

```
GET  /health      → {"status": "ok", "version": "X.Y.Z", "env": "prod"}
GET  /products    → lista de productos desde DynamoDB (o mock en v1-v2)
POST /orders      → crea orden y publica evento en SQS
GET  /metrics     → stats básicas de la instancia
```

- **Runtime**: Python 3.12 + FastAPI
- **Imagen base**: `python:3.12-slim` (luego migra a `python:3.12-alpine`)
- **Puerto**: 8080
- **Código**: [app/](./app/)

---

## Prerrequisitos

### Herramientas
```bash
# Verificar versiones mínimas
aws --version          # 2.x
docker --version       # 24.x
terraform --version    # 1.6+
terragrunt --version   # 0.54+ (desde v5)
```

### Cuenta AWS
- Cuenta AWS con permisos de administrador (para el lab)
- AWS CLI configurado: `aws configure` o perfiles con SSO
- Región por defecto: **eu-west-1** (Ireland)

### Variables de entorno recomendadas
```bash
export AWS_REGION=eu-west-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export PROJECT_PREFIX=shopapi
echo "Account: $AWS_ACCOUNT_ID | Region: $AWS_REGION"
```

---

## Convención de nombres

| Recurso | Nombre |
|---------|--------|
| ECR Repository | `shopapi/api` |
| ECS Cluster | `shopapi-cluster` |
| ECS Service | `shopapi-api` |
| Task Definition | `shopapi-api` |
| ALB | `shopapi-alb` |
| VPC | `shopapi-vpc` |
| Secrets | `shopapi/prod/db` |
| CloudWatch Log Group | `/ecs/shopapi` |

---

## Limpieza de costes

> ⚠️ **Importante**: AWS cobra por recursos activos. Después de cada lab, ejecuta el cleanup.

```bash
# Cleanup rápido (orden correcto para evitar dependencias)
aws ecs update-service --cluster shopapi-cluster --service shopapi-api --desired-count 0
aws ecs delete-service --cluster shopapi-cluster --service shopapi-api --force
aws ecs delete-cluster --cluster shopapi-cluster
# (ver README de cada lab para cleanup completo)
```

---

## Estructura de cada lab

Cada carpeta `vX-nombre/` tiene:
```
vX-nombre/
├── README.md           ← Lab principal: contexto, pasos, validación, cleanup
├── cli/                ← Scripts bash con comandos AWS CLI anotados
│   ├── 00-prereqs.sh   ← Verificación de prerrequisitos
│   ├── 01-setup.sh     ← Configuración inicial
│   └── 99-cleanup.sh   ← Cleanup de todos los recursos
├── terraform/          ← IaC equivalente al lab manual
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
└── troubleshooting/    ← (solo v3+) Escenarios de fallos comunes
```

---

## Conexión con el examen SA Associate

| Tema examen | Labs que lo cubren |
|-------------|-------------------|
| ECS Fargate básico | v1, v2 |
| Task Definition y Service | v1, v2, v3 |
| Networking awsvpc + ALB | v2 |
| IAM Task Role vs Execution Role | v3 |
| Secrets Manager integración | v3 |
| Health checks (3 capas) | v2, v3 |
| Application Auto Scaling | v4 |
| Multi-AZ design | v4 |
| SQS + ECS workers pattern | v4 |
| Fargate Spot | v4, v6 |
| CI/CD con ECS | v5 |
| VPC Endpoints para ECR | v6 |
| Capacity Providers | v6 |
| Cost optimization | v6 |

---

*Documentos conceptuales de referencia: [concept-map/](../concept-map/)*
