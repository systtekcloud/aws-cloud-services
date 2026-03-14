# Lab 01 — PrivateLink con CIDRs solapados

> **Prioridad:** ALTA — Concepto avanzado, muy visual, frecuente en entrevistas y SAA-C03
> **Coste estimado:** < $0.50 si se destruye en < 1h
> **Región:** eu-west-1

---

## Concepto demostrado

Dos VPCs con **el mismo CIDR** (`10.0.0.0/16`) se comunican a través de **AWS PrivateLink** (NLB + Interface Endpoint).

**VPC Peering requiere CIDRs no solapados** porque opera como enrutamiento IP: AWS añade una ruta estática `10.0.0.0/16 → pcx-xxxx` en la tabla de rutas. Con dos VPCs con el mismo CIDR, esa ruta es ambigua — AWS rechaza el peering.

**PrivateLink no usa enrutamiento IP entre VPCs.** El consumidor se conecta a la IP de la ENI del Interface Endpoint en *su propia VPC*. AWS gestiona internamente el reenvío al NLB del proveedor. Los CIDRs de ambas VPCs son completamente irrelevantes.

---

## Diagrama de red

```
┌─────────────────────────────────────────────────────────────────────┐
│                        AWS Account (eu-west-1a)                     │
│                                                                     │
│  ┌──────────────────────────────┐   ┌──────────────────────────┐   │
│  │  VPC-A — Consumer            │   │  VPC-B — Provider        │   │
│  │  CIDR: 10.0.0.0/16  ◄──────────── CIDR: 10.0.0.0/16        │   │
│  │  (mismo CIDR que VPC-B!)     │   │  (mismo CIDR que VPC-A!) │   │
│  │                              │   │                          │   │
│  │  subnet pública 10.0.1.0/24  │   │  subnet privada          │   │
│  │  ┌───────────────┐           │   │  10.0.2.0/24             │   │
│  │  │ Consumer EC2  │           │   │  ┌──────────────────┐    │   │
│  │  │ (AL2023)      │           │   │  │ Provider EC2     │    │   │
│  │  │ SSM Agent     │           │   │  │ Python HTTP :8080│    │   │
│  │  └───────┬───────┘           │   │  └────────┬─────────┘    │   │
│  │          │ curl :8080        │   │           │              │   │
│  │          ▼                   │   │  ┌────────▼─────────┐    │   │
│  │  ┌───────────────┐           │   │  │  NLB (internal)  │    │   │
│  │  │ Interface     │           │   │  │  TCP :8080       │    │   │
│  │  │ Endpoint ENI  │ ──────────────►  └──────────────────┘    │   │
│  │  │ (IP: 10.0.1.x)│  PrivateLink   │                          │   │
│  │  └───────────────┘  tunnel    │   │  Endpoint Service        │   │
│  │                               │   │  (com.amazonaws.vpce...) │   │
│  │  [IGW] → Internet             │   └──────────────────────────┘   │
│  │  (solo para SSM agent)        │                                   │
│  └───────────────────────────────┘                                   │
│                                                                       │
│  ╳ VPC Peering: IMPOSIBLE — CIDRs solapados (10.0.0.0/16 en ambas)  │
│  ✓ PrivateLink: FUNCIONA — no depende de enrutamiento IP entre VPCs  │
└───────────────────────────────────────────────────────────────────────┘
```

### Flujo del tráfico

```
Consumer EC2 (VPC-A)
  │
  │ curl http://vpce-xxx.eu-west-1.vpce.amazonaws.com:8080/
  │
  ▼
Interface Endpoint ENI (10.0.1.x — en la subnet de VPC-A)
  │
  │ [túnel PrivateLink — sin IP routing entre VPCs]
  │
  ▼
NLB interno (VPC-B, 10.0.2.x)
  │
  ▼
Provider EC2 (VPC-B, 10.0.2.y) → responde con JSON
```

---

## Prerequisitos

```bash
# 1. Terraform >= 1.10 (para S3 native locking)
terraform version

# 2. Terragrunt instalado
terragrunt --version

# 3. AWS CLI configurado (perfil con permisos EC2, VPC, IAM, ELB, SSM)
aws sts get-caller-identity

# 4. Crear el bucket S3 para el estado remoto (solo la primera vez)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3 mb s3://networking-labs-tfstate-${ACCOUNT_ID}-eu-west-1 --region eu-west-1
aws s3api put-bucket-versioning \
  --bucket networking-labs-tfstate-${ACCOUNT_ID}-eu-west-1 \
  --versioning-configuration Status=Enabled
```

---

## Despliegue

```bash
# Desde la raíz del lab
cd networking/labs/lab01-privatelink-cidr-overlap/terragrunt

# Plan — ver qué se va a crear
terragrunt plan

# Apply — crear los recursos (~3-4 min, el NLB tarda en estar healthy)
terragrunt apply

# Ver outputs con comandos de validación
terragrunt output summary
```

---

## Validación

### Paso 1 — Verificar que VPC Peering fallaría

```bash
# Obtener los IDs de las VPCs
VPC_A=$(terragrunt output -raw vpc_a_id)
VPC_B=$(terragrunt output -raw vpc_b_id)

echo "VPC-A CIDR: $(aws ec2 describe-vpcs --vpc-ids $VPC_A --query 'Vpcs[0].CidrBlock' --output text)"
echo "VPC-B CIDR: $(aws ec2 describe-vpcs --vpc-ids $VPC_B --query 'Vpcs[0].CidrBlock' --output text)"
# Ambas deben mostrar: 10.0.0.0/16

# Intentar crear VPC Peering — DEBE FALLAR con "CidrBlock overlaps with peer"
aws ec2 create-vpc-peering-connection \
  --vpc-id $VPC_A \
  --peer-vpc-id $VPC_B \
  --region eu-west-1
# Error esperado: An error occurred (InvalidVpcPeeringConnectionId.Overlapping)
#   → "VpcPeeringConnection.VpcCidrBlock overlaps with peer"
```

### Paso 2 — Verificar conectividad via PrivateLink

```bash
# Usar el script de validación automático
chmod +x validate.sh
./validate.sh

# O manualmente con SSM Session Manager:
CONSUMER_ID=$(cd terragrunt && terragrunt output -raw consumer_instance_id)
aws ssm start-session --target $CONSUMER_ID --region eu-west-1

# Dentro de la sesión SSM, ejecutar:
ENDPOINT_DNS=$(cd /path/to/terragrunt && terragrunt output -raw endpoint_dns_name)
curl -s http://$ENDPOINT_DNS:8080/
```

### Respuesta esperada

```json
{
  "status": "OK",
  "message": "Tráfico recibido via AWS PrivateLink",
  "server": "provider-vpc-b",
  "vpc": "VPC-B (Provider) — CIDR 10.0.0.0/16",
  "concept": "PrivateLink funciona con CIDRs solapados. VPC Peering no.",
  "path": "/",
  "client_ip": "10.0.1.x",
  "timestamp": "2026-03-13T..."
}
```

### Paso 3 — Entender el routing

```bash
# Dentro de la sesión SSM en Consumer EC2:

# El endpoint DNS resuelve a la IP de la ENI en la subnet de VPC-A (10.0.1.x)
nslookup $ENDPOINT_DNS
# → 10.0.1.x (IP de la ENI del endpoint — en VPC-A, no en VPC-B)

# traceroute muestra que el tráfico NO cruza ningún router IP externo
traceroute -n -m 5 $ENDPOINT_DNS
# → El primer y único salto es la ENI del endpoint (10.0.1.x)
# No hay IPs de VPC-B visibles — el túnel PrivateLink es transparente
```

---

## Costes estimados

| Recurso | Precio | 1 hora |
|---------|--------|--------|
| EC2 t3.micro × 2 | $0.0104/h cada uno | $0.021 |
| NLB | $0.008/h | $0.008 |
| Interface Endpoint | $0.01/h | $0.010 |
| LCU NLB (mínimo) | ~$0.006/h | $0.006 |
| Endpoint Service | $0.01/h | $0.010 |
| **Total** | | **~$0.055/h** |

> Si el lab dura < 1h: **< $0.06**. Si se extiende a 8h (una mañana): ~$0.44.

---

## Cleanup

```bash
cd networking/labs/lab01-privatelink-cidr-overlap/terragrunt
terragrunt destroy

# Verificar que no queda nada facturando
aws ec2 describe-instances \
  --filters "Name=tag:Lab,Values=lab01-privatelink" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' \
  --output table --region eu-west-1
```

> ⚠️ Los Interface Endpoints y NLBs tienen coste por hora. Destruir siempre al terminar el lab.

---

## Conceptos clave para el examen

| Concepto | VPC Peering | PrivateLink |
|----------|-------------|-------------|
| Funciona con CIDRs solapados | ❌ | ✅ |
| Enrutamiento IP entre VPCs | ✅ (requiere tablas de rutas) | ❌ (ENI en la VPC del consumidor) |
| Backend requerido | Ninguno | NLB obligatorio |
| Dirección del tráfico | Bidireccional | Unidireccional (proveedor→consumidor) |
| Escalabilidad | Limitado (hasta 125 peeringsrings) | Ilimitado (múltiples consumidores) |
| El consumidor ve IPs del proveedor | ✅ | ❌ (solo ve IP de la ENI) |

---

*Lab01 · Networking Labs · SAA-C03 · eu-west-1*
