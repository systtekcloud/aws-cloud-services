# Lab 02 — Gateway Endpoint vs NAT Gateway para S3

**Concepto:** Demostrar con VPC Flow Logs que el tráfico S3 desde una subnet con Gateway Endpoint no pasa por NAT Gateway, mientras que sin él sí lo hace.

**Coste estimado:** < $0.10 si se destruye en < 1h
**Stack:** Terraform >= 1.10 · Terragrunt · eu-west-1

---

## Diagrama

```
                         ┌─────────────────────────────────────────────────┐
                         │  VPC 10.0.0.0/16                                │
                         │                                                  │
                         │  ┌─────────────────────┐                        │
                         │  │  subnet-public       │                        │
                         │  │  10.0.0.0/24         │                        │
                         │  │  [NAT Gateway] ──────┼──── IGW ──── Internet  │
                         │  └─────────────────────┘                        │
                         │                                                  │
  S3 Gateway Endpoint    │  ┌─────────────────────┐                        │
  (interno AWS, gratis)  │  │  subnet-gw-private   │                        │
  ◄──────────────────────┼──│  10.0.1.0/24         │                        │
                         │  │  [EC2-A]             │                        │
                         │  │  Route: S3 → GW EP   │                        │
                         │  │         0/0 → NAT    │                        │
                         │  └─────────────────────┘                        │
                         │                                                  │
                         │  ┌─────────────────────┐                        │
                         │  │  subnet-nat-private  │                        │
                         │  │  10.0.2.0/24         │                        │
                         │  │  [EC2-B]             │                        │
                         │  │  Route: 0/0 → NAT ───┼── NAT GW ── IGW ─► S3 │
                         │  └─────────────────────┘                        │
                         │                                                  │
                         │  VPC Flow Logs → CloudWatch                      │
                         └─────────────────────────────────────────────────┘
```

**EC2-A → S3:** tráfico va por el Gateway Endpoint (sin pasar por NAT)
**EC2-B → S3:** tráfico va 0.0.0.0/0 → NAT GW → IGW → IP pública S3

---

## Por qué importa esto

| | Gateway Endpoint | Sin Gateway Endpoint (NAT) |
|--|--|--|
| Coste transferencia | **$0.00** | ~$0.045/GB via NAT |
| Latencia | Menor (ruta interna AWS) | Mayor (sale a internet y vuelve) |
| Disponibilidad desde on-prem | No | Sí (via Direct Connect + Interface EP) |
| Servicios soportados | Solo S3 y DynamoDB | Todos |

---

## Despliegue

### Pre-requisitos

```bash
# Terraform >= 1.10 y Terragrunt instalados
terraform version   # >= 1.10.0
terragrunt version

# Bucket de estado (usar mismo que lab01, ya debería existir)
aws s3 ls s3://networking-labs-tfstate-$(aws sts get-caller-identity --query Account --output text)-eu-west-1

# Si no existe:
aws s3 mb s3://networking-labs-tfstate-$(aws sts get-caller-identity --query Account --output text)-eu-west-1 \
  --region eu-west-1
```

### Desplegar

```bash
cd terragrunt
terragrunt init
terragrunt plan    # Revisar: 1 VPC, 3 subnets, 1 NAT GW, 1 S3 EP, 2 EC2, Flow Logs
terragrunt apply
```

### Validar

```bash
cd ..
./validate.sh
```

El script:
1. Lee outputs (IDs, IPs, nombre bucket)
2. Sube 5MB a S3 desde cada EC2 via SSM Run Command
3. Espera 90s para que los Flow Logs lleguen a CloudWatch
4. Consulta CloudWatch Logs Insights
5. Muestra bytes que pasaron por NAT GW por cada EC2

**Resultado esperado:**
```
EC2-A (Gateway Endpoint) (10.0.1.x): 0 bytes via NAT
EC2-B (NAT only)         (10.0.2.x): ~5,242,880 bytes via NAT
```

### Verificación manual en consola

1. **CloudWatch → Log Insights** → seleccionar `/aws/vpc/flow-logs/lab02`
2. Ejecutar query:
```
fields srcaddr, dstaddr, bytes, action
| filter dstaddr = "<NAT_GW_IP>"
| stats sum(bytes) as total by srcaddr
```

### Destruir

```bash
cd terragrunt
terragrunt destroy
```

**Recursos con coste por hora:**
- NAT Gateway: $0.045/h — destruir cuando termines

---

## Archivos

```
lab02-gateway-vs-interface-endpoint-s3/
├── README.md              ← Este fichero
├── validate.sh            ← Script de validación automática
├── terraform/
│   ├── vpc.tf             ← VPC, subnets, IGW, NAT GW, route tables
│   ├── endpoints.tf       ← S3 Gateway Endpoint (solo subnet-gw)
│   ├── ec2.tf             ← EC2-A y EC2-B con IAM SSM+S3
│   ├── flow_logs.tf       ← VPC Flow Logs → CloudWatch
│   ├── s3.tf              ← Bucket de test
│   ├── security_groups.tf ← Sin SSH, solo SSM
│   ├── variables.tf
│   └── outputs.tf
└── terragrunt/
    └── terragrunt.hcl     ← Backend S3 native locking
```
