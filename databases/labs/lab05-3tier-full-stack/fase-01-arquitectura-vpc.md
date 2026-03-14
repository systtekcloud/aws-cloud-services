# Fase 01 — Arquitectura VPC 3-Tier

## Objetivo

Crear una VPC con **6 subnets en 2 AZs** separando los 3 tiers (público, app, DB) y añadir los VPC Endpoints necesarios para que DynamoDB y Secrets Manager sean accesibles sin salir a internet.

**Tiempo estimado:** 25-30 minutos

---

## Diseño de red

```
VPC: 10.20.0.0/16 (vpc-lab05-3tier)

┌───────────────────────────────────────────────────────────┐
│  AZ eu-west-1a                  AZ eu-west-1b             │
│                                                            │
│  10.20.0.0/24  PUBLIC-A         10.20.1.0/24  PUBLIC-B   │
│  (ALB, NAT GW)                  (ALB, NAT GW)             │
│                                                            │
│  10.20.10.0/24 PRIVATE-APP-A    10.20.11.0/24 APP-B      │
│  (EC2, Lambda, ECS)                                       │
│                                                            │
│  10.20.20.0/24 PRIVATE-DB-A     10.20.21.0/24 DB-B       │
│  (Aurora, Redis)                (Aurora, Redis)            │
└───────────────────────────────────────────────────────────┘

IGW → Public subnets
NAT GW (eu-west-1a) → Private App + Private DB
Gateway VPC Endpoint (DynamoDB) → Private App
Interface VPC Endpoints (Secrets Manager, SSM) → Private App
```

---

## Paso 1 — VPC y subnets

### Consola

1. **VPC → Your VPCs → Create VPC**
2. VPC only
3. Name: `vpc-lab05-3tier`
4. IPv4 CIDR: `10.20.0.0/16`
5. Tenancy: Default
6. **Create VPC**

7. **Enable DNS hostnames** (Actions → Edit VPC settings → ✅ Enable DNS hostnames)

### Crear 6 subnets

**VPC → Subnets → Create subnet** (repetir 6 veces):

| Nombre | CIDR | AZ | Tier |
|--------|------|----|------|
| `subnet-public-a` | 10.20.0.0/24 | eu-west-1a | Public |
| `subnet-public-b` | 10.20.1.0/24 | eu-west-1b | Public |
| `subnet-private-app-a` | 10.20.10.0/24 | eu-west-1a | App |
| `subnet-private-app-b` | 10.20.11.0/24 | eu-west-1b | App |
| `subnet-private-db-a` | 10.20.20.0/24 | eu-west-1a | DB |
| `subnet-private-db-b` | 10.20.21.0/24 | eu-west-1b | DB |

<details>
<summary>CLI equivalente — ver cli/01-vpc-extendida.sh para el script completo</summary>

```bash
# Snippet clave
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.20.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=vpc-lab05-3tier},{Key=Project,Value=db-labs}]" \
  --query 'Vpc.VpcId' --output text --region eu-west-1)

# Habilitar DNS
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
```

</details>

---

## Paso 2 — Internet Gateway y NAT Gateway

### Internet Gateway

1. **VPC → Internet gateways → Create internet gateway**
2. Name: `igw-lab05`
3. **Attach to VPC** → `vpc-lab05-3tier`

### NAT Gateway

1. **VPC → NAT gateways → Create NAT gateway**
2. Name: `nat-lab05-a`
3. Subnet: `subnet-public-a`
4. Elastic IP: **Allocate Elastic IP** → usar la nueva
5. **Create**

---

## Paso 3 — Route Tables

Necesitas **3 route tables**:

| RT | Para | Ruta añadida |
|----|------|-------------|
| `rt-public` | Public subnets | 0.0.0.0/0 → IGW |
| `rt-private-app` | App subnets | 0.0.0.0/0 → NAT GW |
| `rt-private-db` | DB subnets | 0.0.0.0/0 → NAT GW |

### RT Public
1. Crear → Name: `rt-public` → VPC: `vpc-lab05-3tier`
2. **Routes → Add route**: `0.0.0.0/0` → `igw-lab05`
3. **Subnet associations**: `subnet-public-a`, `subnet-public-b`

### RT Private App
1. Crear → Name: `rt-private-app`
2. **Routes → Add route**: `0.0.0.0/0` → NAT Gateway `nat-lab05-a`
3. **Subnet associations**: `subnet-private-app-a`, `subnet-private-app-b`

### RT Private DB
1. Crear → Name: `rt-private-db`
2. **Routes → Add route**: `0.0.0.0/0` → NAT Gateway `nat-lab05-a`
3. **Subnet associations**: `subnet-private-db-a`, `subnet-private-db-b`

---

## Paso 4 — Security Groups (en cascada)

Crea los 4 SGs en orden (cada uno referencia al anterior):

### SG-ALB (entrada desde internet)
```
Name:     sg-alb-lab05
Inbound:  HTTP 80  → 0.0.0.0/0
          HTTPS 443 → 0.0.0.0/0
Outbound: All
```

### SG-App (entrada solo desde ALB)
```
Name:     sg-app-lab05
Inbound:  TCP 8080 → sg-alb-lab05
          TCP 22   → 10.20.0.0/16 (gestión interna)
Outbound: All
```

### SG-Aurora (entrada solo desde App)
```
Name:     sg-aurora-lab05
Inbound:  TCP 3306 → sg-app-lab05
Outbound: All
```

### SG-Redis (entrada solo desde App)
```
Name:     sg-redis-lab05
Inbound:  TCP 6379 → sg-app-lab05
Outbound: All
```

<details>
<summary>CLI para los 4 SGs</summary>

```bash
# sg-alb
SG_ALB=$(aws ec2 create-security-group \
  --group-name sg-alb-lab05 --description "ALB - public" \
  --vpc-id $VPC_ID --query 'GroupId' --output text --region eu-west-1)
aws ec2 authorize-security-group-ingress --group-id $SG_ALB \
  --ip-permissions IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}] \
  IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}] --region eu-west-1

# sg-app
SG_APP=$(aws ec2 create-security-group \
  --group-name sg-app-lab05 --description "App tier - from ALB only" \
  --vpc-id $VPC_ID --query 'GroupId' --output text --region eu-west-1)
aws ec2 authorize-security-group-ingress --group-id $SG_APP \
  --protocol tcp --port 8080 --source-group $SG_ALB --region eu-west-1

# sg-aurora
SG_AURORA=$(aws ec2 create-security-group \
  --group-name sg-aurora-lab05 --description "Aurora - from App only" \
  --vpc-id $VPC_ID --query 'GroupId' --output text --region eu-west-1)
aws ec2 authorize-security-group-ingress --group-id $SG_AURORA \
  --protocol tcp --port 3306 --source-group $SG_APP --region eu-west-1

# sg-redis
SG_REDIS=$(aws ec2 create-security-group \
  --group-name sg-redis-lab05 --description "Redis - from App only" \
  --vpc-id $VPC_ID --query 'GroupId' --output text --region eu-west-1)
aws ec2 authorize-security-group-ingress --group-id $SG_REDIS \
  --protocol tcp --port 6379 --source-group $SG_APP --region eu-west-1
```

</details>

---

## Paso 5 — VPC Endpoints

### Gateway Endpoint para DynamoDB (sin coste)

1. **VPC → Endpoints → Create endpoint**
2. Service category: **AWS services**
3. Busca: `com.amazonaws.eu-west-1.dynamodb`
4. Type: **Gateway**
5. VPC: `vpc-lab05-3tier`
6. Route tables: selecciona `rt-private-app` y `rt-private-db`
7. **Create endpoint**

Esto añade una ruta automática a las RT: `pl-XXXXX (com.amazonaws.eu-west-1.dynamodb) → vpce-XXXX`

### Interface Endpoint para Secrets Manager

1. **Create endpoint** → `com.amazonaws.eu-west-1.secretsmanager`
2. Type: **Interface**
3. VPC: `vpc-lab05-3tier`
4. Subnets: `subnet-private-app-a`, `subnet-private-app-b`
5. SG: `sg-app-lab05`
6. **Enable private DNS name** ✅
7. **Create**

### Interface Endpoint para SSM (para Session Manager)

1. Repetir para: `com.amazonaws.eu-west-1.ssm`
2. Y también: `com.amazonaws.eu-west-1.ssmmessages`
3. Y: `com.amazonaws.eu-west-1.ec2messages`

<details>
<summary>CLI para VPC Endpoints</summary>

```bash
# Gateway DynamoDB
aws ec2 create-vpc-endpoint \
  --vpc-id $VPC_ID \
  --service-name com.amazonaws.eu-west-1.dynamodb \
  --vpc-endpoint-type Gateway \
  --route-table-ids $RT_PRIVATE_APP $RT_PRIVATE_DB \
  --region eu-west-1

# Interface Secrets Manager
aws ec2 create-vpc-endpoint \
  --vpc-id $VPC_ID \
  --service-name com.amazonaws.eu-west-1.secretsmanager \
  --vpc-endpoint-type Interface \
  --subnet-ids $SUBNET_APP_A $SUBNET_APP_B \
  --security-group-ids $SG_APP \
  --private-dns-enabled \
  --region eu-west-1
```

</details>

---

## Paso 6 — EC2 App Server (simula la capa de aplicación)

### IAM Role para la EC2

1. **IAM → Roles → Create role → EC2**
2. Attach policies:
   - `AmazonSSMManagedInstanceCore`
   - `AmazonDynamoDBFullAccess` (lab — en prod usar política mínima)
   - `SecretsManagerReadWrite`
3. Name: `ec2-app-lab05-role`

### EC2

1. **EC2 → Launch instance**
2. Name: `app-server-lab05`
3. AMI: Amazon Linux 2023
4. Instance type: `t3.micro`
5. Network: `vpc-lab05-3tier` / `subnet-private-app-a`
6. No public IP
7. IAM profile: `ec2-app-lab05-role`
8. SG: `sg-app-lab05`
9. **Launch**

### Instalar herramientas en la EC2

```bash
# Conectar via SSM
aws ssm start-session --target i-XXXX --region eu-west-1

# Una vez dentro:
sudo dnf install -y mysql redis jq python3-pip
pip3 install redis pymysql boto3
```

---

## ✅ Validaciones de la fase

```bash
# 1. VPC y subnets
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[*].{Name:Tags[?Key==`Name`]|[0].Value,CIDR:CidrBlock,AZ:AvailabilityZone}' \
  --output table --region eu-west-1
# 6 subnets

# 2. Gateway Endpoint DynamoDB en las route tables
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[*].Routes[?contains(DestinationPrefixListId,`pl-`)].DestinationPrefixListId' \
  --output text --region eu-west-1
# Debe mostrar pl-XXXXXX (DynamoDB prefix list)

# 3. EC2 accesible via SSM
aws ssm describe-instance-information \
  --filters "Key=tag:Project,Values=db-labs" \
  --query 'InstanceInformationList[0].{ID:InstanceId,Status:PingStatus}' \
  --output table --region eu-west-1
```
