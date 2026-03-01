# v5 — Enterprise IaC: Terragrunt + Atmos + GitOps

Organiza todo lo construido en v1-v4 usando herramientas IaC de nivel enterprise: **Terragrunt** para DRY multi-entorno y **Atmos** para orquestación stack-based. GitHub Actions implementa el flujo GitOps: plan en PR, apply en merge a main.

```
Repositorio
├── terragrunt/              ← Enfoque Terragrunt (DRY HCL)
│   ├── terragrunt.hcl       ← Root config: remote state, provider, tags
│   ├── _modules/            ← Módulos Terraform reutilizables
│   │   ├── vpc/
│   │   ├── compute/
│   │   ├── database/
│   │   └── dns/
│   ├── dev/
│   │   └── eu-west-1/
│   │       ├── env.hcl
│   │       ├── vpc/terragrunt.hcl
│   │       ├── compute/terragrunt.hcl
│   │       └── database/terragrunt.hcl
│   └── prod/
│       └── eu-west-1/
│           └── (idem)
│
├── atmos/                   ← Enfoque Atmos (stack-based)
│   ├── atmos.yaml
│   ├── components/terraform/
│   │   ├── vpc/
│   │   ├── compute/
│   │   └── database/
│   └── stacks/
│       ├── globals.yaml
│       ├── dev.yaml
│       └── prod.yaml
│
└── .github/workflows/
    ├── plan.yml             ← terraform plan en cada PR
    └── apply.yml            ← terraform apply en merge a main
```

---

## Terragrunt vs Atmos

| Característica | Terragrunt | Atmos |
|---|---|---|
| Enfoque | DRY HCL wrapper | Stack YAML orchestrator |
| Remote state | Auto-generado por componente | Configurable |
| Multi-entorno | `env.hcl` + heredado | `stacks/*.yaml` |
| Dependencias | `dependency {}` blocks | `vars` entre componentes |
| Curva de aprendizaje | Media | Media-alta |
| Ideal para | Equipos ya en Terraform | Plataformas complejas |

**Recomendación para el examen SA-Associate:** entender ambos conceptos; Terragrunt es más común en la industria para este nivel.

---

## Fase A — Terragrunt

```bash
# Instalar
brew install terragrunt  # o tfenv + mise

# Planificar entorno dev completo
cd terragrunt/dev/eu-west-1
terragrunt run-all plan

# Aplicar
terragrunt run-all apply

# Solo un componente
cd terragrunt/dev/eu-west-1/compute
terragrunt plan
terragrunt apply
```

## Fase B — Atmos

```bash
# Instalar
brew install atmos

# Plan stack dev
atmos terraform plan vpc -s dev
atmos terraform plan compute -s dev

# Apply
atmos terraform apply vpc -s dev
atmos terraform apply compute -s dev

# Apply todo el stack
atmos workflow deploy -f workflows/deploy-all.yaml -w deploy-stack
```

---

## Exam Traps

| Trampa | Realidad |
|---|---|
| Terragrunt reemplaza Terraform | Terragrunt es un wrapper; genera y ejecuta HCL de Terraform |
| Remote state S3 requiere DynamoDB para locks | DynamoDB lock es opcional pero recomendado para equipos; S3 solo no previene conflictos |
| `terragrunt run-all apply` aplica en paralelo | Por defecto respeta dependencias `dependency {}`; sí paraleliza cuando no hay deps |
| Atmos es una herramienta de AWS | Atmos es open-source de Cloud Posse, no de AWS |
