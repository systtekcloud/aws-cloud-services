# Lab 02 — IAM Access Analyzer

> **Coste:** GRATIS siempre | **Región:** `eu-west-1` | **Duración estimada:** 45-60 minutos

---

## Por qué este lab

IAM Access Analyzer es gratuito, no requiere prerequisitos, y el concepto de **zona de confianza** (trust zone) aparece frecuentemente en el examen SAA-C03 — especialmente en contexto de buckets S3 expuestos y roles IAM con acceso cross-account.

---

## Concepto central

Access Analyzer analiza **resource-based policies** y genera un **finding** cuando detecta que un recurso permite acceso desde fuera de tu zona de confianza (tu cuenta o tu organización). No detecta amenazas activas — detecta **configuraciones de acceso** que podrían ser un riesgo.

```
Resource-based policy → acceso externo?
  Sí → Finding ACTIVE
    ↓
  ¿Intencionado? → Archive (documentar)
  ¿Error?        → Corregir política → Finding RESOLVED (automático)
```

---

## Recursos analizados

S3 Buckets · IAM Roles · KMS Keys · Lambda Functions · SQS Queues · Secrets Manager · SNS Topics

---

## Estructura del lab

| Lab | Concepto | Duración |
|-----|---------|---------|
| [01-setup](labs/01-setup/README.md) | Crear analyzer, ver findings iniciales | 15 min |
| [02-findings](labs/02-findings/README.md) | S3 cross-account → finding → archive → remediar | 15 min |
| [03-bucket-exposed](labs/03-bucket-exposed/README.md) | S3 público (`isPublic: true`) → finding → remediar con BPA | 10 min |
| [04-cross-account](labs/04-cross-account/README.md) | IAM Role con trust policy cross-account → archive vs remediar | 15 min |

---

## Concept map

Ver [concept-map/README.md](concept-map/README.md) para:
- Zona de confianza: cuenta vs organización
- Estados de findings: Active, Archived, Resolved
- Diferencia con GuardDuty, Macie, Config, Security Hub

## Escenarios SAA-C03

Ver [scenarios/README.md](scenarios/README.md) — 3 escenarios típicos del examen.

## Terraform

Ver [terraform/main.tf](terraform/main.tf) — crea el analyzer + recursos de prueba parametrizables.

## Cleanup

Ver [cleanup.md](cleanup.md) — eliminar todos los recursos en orden correcto.

---

## Comandos rápidos

```bash
# Crear analyzer
aws accessanalyzer create-analyzer \
  --analyzer-name "lab02-account-analyzer" \
  --type ACCOUNT \
  --region eu-west-1

# Listar findings activos
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws accessanalyzer list-findings \
  --analyzer-arn "arn:aws:access-analyzer:eu-west-1:${ACCOUNT_ID}:analyzer/lab02-account-analyzer" \
  --filter '{"status": {"eq": ["ACTIVE"]}}' \
  --region eu-west-1 \
  --output table

# Eliminar analyzer al terminar
aws accessanalyzer delete-analyzer \
  --analyzer-name "lab02-account-analyzer" \
  --region eu-west-1
```
