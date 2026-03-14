# Lab 02 — Gateway Endpoint vs Interface Endpoint S3 — Design Doc

**DATP-2028 · Post SAA-C03 · eu-west-1**

---

## Goal

Demostrar que el tráfico S3 desde una subnet con Gateway Endpoint NO pasa por NAT Gateway, mientras que el tráfico desde una subnet sin Gateway Endpoint SÍ consume NAT, visible en VPC Flow Logs.

## Enfoque elegido

**Enfoque A — Dos subnets privadas en la misma VPC.**
Comparación simultánea: una EC2 en subnet con Gateway Endpoint, otra en subnet sin él (solo NAT GW). Un solo `terraform apply`, Flow Logs captura ambos flujos al mismo tiempo.

## Arquitectura

```
VPC (10.0.0.0/16) — eu-west-1
│
├── subnet-public (10.0.0.0/24)
│   └── NAT Gateway → IGW
│
├── subnet-gw-private (10.0.1.0/24)
│   ├── EC2-A (t3.micro)
│   └── Route table: 0.0.0.0/0 → NAT GW | pl-xxxxx (S3) → Gateway Endpoint
│
└── subnet-nat-private (10.0.2.0/24)
    ├── EC2-B (t3.micro)
    └── Route table: 0.0.0.0/0 → NAT GW (sin entrada S3)

S3 Gateway Endpoint → asociado SOLO a subnet-gw-private
VPC Flow Logs → CloudWatch Logs (todos los ENIs)
S3 bucket de test → para generar tráfico desde ambas EC2
```

## Componentes Terraform

| Archivo | Contenido |
|---------|-----------|
| `vpc.tf` | VPC, 3 subnets, IGW, EIP, NAT GW, 2 route tables privadas diferenciadas |
| `endpoints.tf` | `aws_vpc_endpoint` tipo Gateway para S3, asociado solo a `subnet-gw-private` |
| `ec2.tf` | EC2-A y EC2-B con IAM Instance Profile (S3 read/write + SSM) |
| `flow_logs.tf` | `aws_flow_log` sobre la VPC → CloudWatch Log Group (retención 1 día) |
| `s3.tf` | Bucket de test con nombre único, sin acceso público |
| `security_groups.tf` | SG sin puerto 22 — acceso solo via SSM Session Manager |
| `variables.tf` | region, vpc_cidr, ami_id, instance_type, bucket_name |
| `outputs.tf` | IDs de EC2-A/B, NAT GW IP, endpoint ID, CloudWatch log group |
| `terragrunt/terragrunt.hcl` | Backend S3 con native locking (s3_native_locking = true) |

## Validación (validate.sh)

1. Sube fichero 10MB al bucket S3 desde EC2-A (via SSM Run Command)
2. Sube fichero 10MB al bucket S3 desde EC2-B (via SSM Run Command)
3. Espera 90 segundos para que los Flow Logs lleguen a CloudWatch
4. Consulta logs filtrando por IP del NAT GW como destino
5. Muestra resultado:
   - EC2-A → S3: 0 bytes via NAT (tráfico fue directo via Gateway Endpoint)
   - EC2-B → S3: ~10MB via NAT (tráfico pasó por NAT GW)

## README

- Diagrama ASCII de la arquitectura
- Pasos: `terragrunt apply` → `./validate.sh` → `terragrunt destroy`
- Explicación del POR QUÉ Gateway Endpoint no requiere NAT
- Coste estimado y recursos con coste por hora

## Coste estimado

| Recurso | Coste/h |
|---------|---------|
| NAT Gateway | $0.045 |
| 2x EC2 t3.micro | ~$0.02 (o free tier) |
| S3 Gateway Endpoint | $0.00 |
| CloudWatch Logs | ~$0.01 |
| **Total < 1h** | **~$0.08** |

## Estructura de carpetas de salida

```
networking/labs/lab02-gateway-vs-interface-endpoint-s3/
├── README.md
├── validate.sh
├── terraform/
│   ├── vpc.tf
│   ├── endpoints.tf
│   ├── ec2.tf
│   ├── flow_logs.tf
│   ├── s3.tf
│   ├── security_groups.tf
│   ├── variables.tf
│   └── outputs.tf
└── terragrunt/
    └── terragrunt.hcl
```

---

*DATP-2028 · Lab 02 Design Doc · 2026-03-14*
