# Lab 05 — Session Manager sin internet: VPC Interface Endpoints

> **Concepto SAA-C03/SCS-C02:** SSM Session Manager funciona sin internet usando 3 VPC Interface Endpoints. Elimina el Bastion Host, el puerto 22, y el NAT GW — mejor seguridad y menor coste para tráfico de gestión.

**Coste estimado:** < $0.10 en < 1h
**Stack:** Terraform ≥ 1.10 · Terragrunt ≥ 0.54 · eu-west-1

---

## Qué demuestra este lab

| Config | SSM funciona | curl (internet) | Recursos |
|--------|-------------|-----------------|---------|
| `internet` | ✓ via NAT GW | ✓ IP del NAT GW | NAT GW + IGW |
| `endpoints` | ✓ via Endpoints | ✗ timeout (zero internet) | 3 Interface Endpoints |

---

## Los 3 endpoints necesarios para SSM

| Endpoint | Para qué |
|----------|---------|
| `ssm` | Registro del agente + polling de comandos |
| `ssmmessages` | Canal de Session Manager (shell interactivo) |
| `ec2messages` | Run Command (comandos no interactivos) |

**Requisitos críticos:**
- `enable_dns_hostnames = true` en la VPC
- `enable_dns_support = true` en la VPC
- `private_dns_enabled = true` en cada endpoint
- SG del endpoint: ingress 443 desde la subnet privada

---

## Diagrama

```
modo "internet":                     modo "endpoints":

VPC                                  VPC (sin IGW, sin NAT)
├── subnet-public                    │
│   └── NAT GW ──► internet          └── subnet-private
└── subnet-private                       ├── EC2 (SSM ✓, internet ✗)
    └── EC2                              ├── ENI endpoint ssm
        SSM Agent ──► NAT ──► SSM        ├── ENI endpoint ssmmessages
        curl ──► NAT ──► ✓              └── ENI endpoint ec2messages
                                         SSM Agent ──► ENI ──► SSM ✓
                                         curl ──► (sin ruta) ──► ✗
```

---

## Despliegue

```bash
# Sustituir <ACCOUNT_ID> en terragrunt/terragrunt.hcl

cd terragrunt/internet   && terragrunt apply
cd terragrunt/endpoints  && terragrunt apply
```

---

## Validación

```bash
./validate.sh internet    # SSM via NAT GW, curl funciona
./validate.sh endpoints   # SSM via endpoints, curl falla (zero internet)
```

---

## Destruir

```bash
cd terragrunt/internet  && terragrunt destroy
cd terragrunt/endpoints && terragrunt destroy
```

---

## Coste

| Config | Coste/h | Coste/mes |
|--------|---------|-----------|
| internet | ~$0.05 (NAT GW) | ~$32 |
| endpoints | ~$0.03 (3 endpoints) | ~$21 |

**Interface Endpoints son más baratos que NAT GW** para tráfico de gestión puro. Si la EC2 solo necesita SSM (no acceso a internet), los endpoints son la mejor opción.
