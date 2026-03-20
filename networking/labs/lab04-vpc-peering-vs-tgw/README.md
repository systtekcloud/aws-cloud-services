# Lab 04 — VPC Peering no transitivo vs Transit Gateway

> **Concepto SAA-C03:** VPC Peering no es transitivo. A↔B y B↔C no implica A↔C. Transit Gateway resuelve el problema de escala del full mesh con N attachments en lugar de N*(N-1)/2 peerings.

**Coste estimado:** < $0.40 en < 1h (destruir al terminar)
**Stack:** Terraform ≥ 1.10 · Terragrunt ≥ 0.54 · eu-west-1
**Acceso EC2:** SSM Session Manager (sin SSH, sin bastión)

---

## Qué demuestra este lab

| Config | Comportamiento | Concepto |
|--------|---------------|---------|
| `peering-partial` | A↔B ✓, B↔C ✓, A↔C ✗ | No-transitividad del VPC Peering |
| `peering-full` | A↔B ✓, B↔C ✓, A↔C ✓ | Full mesh funciona pero N*(N-1)/2 peerings |
| `tgw` | A↔B ✓, B↔C ✓, A↔C ✓ | TGW: N attachments, routing centralizado |

---

## Diagrama

```
peering-partial:              peering-full:                 tgw:
VPC-A (10.1.0.0/16)          VPC-A (10.1.0.0/16)          VPC-A ──┐
 │ EC2-A                       │ EC2-A                              │
 │ pcx A↔B ✓                  │ pcx A↔B + A↔C ✓                  │
 ↕                             ↕         ↕                         ├── TGW ── (hub)
VPC-B (10.2.0.0/16)          VPC-B     VPC-C               VPC-B ──┤
 │ EC2-B + NAT GW              EC2-B   EC2-C                        │
 │ pcx B↔C ✓                  pcx B↔C ✓                   VPC-C ──┘
 ↕
VPC-C (10.3.0.0/16)
 │ EC2-C
 A → C: ✗ NO PASA
```

---

## Despliegue

```bash
# Verificar que el bucket S3 del backend existe (creado en lab02/lab03)
# Si no existe:
aws s3 mb s3://tfstate-networking-labs-<ACCOUNT_ID> --region eu-west-1

# Sustituir <ACCOUNT_ID> en terragrunt/terragrunt.hcl

# Desplegar el modo que quieras probar:
cd terragrunt/peering-partial && terragrunt apply
cd terragrunt/peering-full    && terragrunt apply
cd terragrunt/tgw             && terragrunt apply
```

---

## Validación

```bash
./validate.sh peering-partial   # Demuestra no-transitividad
./validate.sh peering-full      # Demuestra full mesh + tabla de escala
./validate.sh tgw               # Demuestra TGW como solución
```

---

## Destruir

```bash
cd terragrunt/peering-partial && terragrunt destroy
cd terragrunt/peering-full    && terragrunt destroy
cd terragrunt/tgw             && terragrunt destroy
```

---

## Coste

| Config | Recursos | Coste/h |
|--------|----------|---------|
| peering-partial | 1 NAT GW + 3 EC2 | ~$0.07 |
| peering-full | 1 NAT GW + 3 EC2 | ~$0.07 |
| tgw | 1 NAT GW + 3 EC2 + TGW (3 attachments) | ~$0.22 |

VPC Peering es **gratuito** (solo data transfer $0.01/GB).
TGW cobra **$0.05/h por attachment** + $0.02/GB procesado.
