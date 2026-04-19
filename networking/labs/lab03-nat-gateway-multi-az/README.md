# Lab 03 — NAT Gateway Multi-AZ: Alta Disponibilidad

> **Concepto SAA-C03:** NAT Gateway es zonal. Si su AZ falla, las subnets privadas de otras AZs que enrutan a ese NAT pierden acceso a internet.

**Coste estimado:** < $0.20 si se destruye en < 1h
**Stack:** Terraform ≥ 1.10 · Terragrunt ≥ 0.54 · eu-west-1
**Acceso EC2:** SSM Session Manager (sin SSH, sin bastión)

---

## Concepto demostrado

Un NAT Gateway vive en una subnet pública de una AZ concreta. Si esa AZ falla:
- Las subnets privadas **de esa misma AZ** también fallan (lógico)
- Las subnets privadas de **otras AZs que enrutan a ese NAT** pierden el egress

La solución es simple: **un NAT Gateway por AZ**, con route table propia por subnet privada.

---

## Diagrama

```
SINGLE-AZ (nat_ha = false):                MULTI-AZ (nat_ha = true):

VPC 10.0.0.0/16                            VPC 10.0.0.0/16
│                                          │
├── subnet-public-a  → [NAT-A] → IGW      ├── subnet-public-a  → [NAT-A] → IGW
├── subnet-public-b  (sin NAT)             ├── subnet-public-b  → [NAT-B] → IGW
│                                          │
├── subnet-private-a → NAT-A ✓             ├── subnet-private-a → NAT-A ✓
└── subnet-private-b → NAT-A ⚠️ SPOF      └── subnet-private-b → NAT-B ✓ HA

Fallo AZ-a:                                Fallo AZ-a:
  EC2-A: sin internet (lógico)               EC2-A: sin internet (lógico)
  EC2-B: sin internet ❌ SPOF               EC2-B: internet via NAT-B ✅ HA
```

---

## Despliegue

```bash
# 1. Crear bucket de estado S3 si no existe
aws s3 mb s3://tfstate-networking-labs-<ACCOUNT_ID> --region eu-west-1
aws s3api put-bucket-versioning \
  --bucket tfstate-networking-labs-<ACCOUNT_ID> \
  --versioning-configuration Status=Enabled

# 2. Sustituir <ACCOUNT_ID> en terragrunt/terragrunt.hcl

# 3. Desplegar single-az
cd terragrunt/single-az && terragrunt apply

# 4. Desplegar multi-az (en otra terminal o después)
cd terragrunt/multi-az && terragrunt apply
```

---

## Validación

```bash
# Desde la raíz del lab:
./validate.sh single-az   # Demuestra el SPOF
./validate.sh multi-az    # Demuestra la HA
./validate.sh both        # Ambos en secuencia
```

El script:
1. Verifica conectividad inicial desde EC2-A y EC2-B (`curl ifconfig.me` via SSM)
2. Elimina NAT GW-a para simular fallo de AZ-a
3. Verifica que EC2-B pierde internet en single-az y lo mantiene en multi-az
4. Muestra comparativa de coste

---

## Destruir

```bash
# Cada entorno independientemente:
cd terragrunt/single-az && terragrunt destroy
cd terragrunt/multi-az  && terragrunt destroy
```

---

## Coste

| Recurso | Single-AZ | Multi-AZ |
|---------|-----------|---------|
| NAT Gateway(s) | 1x $0.045/h | 2x $0.045/h |
| EC2 t3.micro x2 | free tier | free tier |
| Cross-AZ data | $0.01/GB (subnet-b → nat-a) | $0 (cada subnet usa su NAT) |
| **< 1h total** | **~$0.05** | **~$0.09** |

---

## Notas

- **NAT GW tarda ~1 min en crearse** — el `depends_on` en `nat.tf` asegura que el IGW exista primero
- **validate.sh elimina NAT GW-a** — tras ejecutarlo, hacer `terragrunt apply` para restaurarlo o `terragrunt destroy` para limpiar todo
- **SSM necesita egress** — las EC2 necesitan llegar a los endpoints de SSM. Como están en subnets privadas con NAT GW, funciona automáticamente. Sin NAT GW, necesitarían VPC Interface Endpoints para SSM (ver Lab 05)
- **S3 native locking** — requiere Terraform ≥ 1.10 y `use_lockfile = true` en el backend. Sin DynamoDB
