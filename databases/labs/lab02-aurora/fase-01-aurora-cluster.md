# Fase 01 — Aurora MySQL: Crear el Cluster

## Objetivo

Crear un Aurora MySQL cluster con Writer + Reader en la misma región, entender la arquitectura de almacenamiento distribuido de Aurora y conectar desde la EC2 usando los dos endpoints distintos.

**Tiempo estimado:** 30-40 minutos
**Coste:** ~0.20€/hora mientras el cluster está activo

---

## Conceptos clave antes de empezar

```
┌───────────────────────────────────────────────────────────────────────┐
│  ARQUITECTURA AURORA (diferente a RDS "normal")                       │
│                                                                        │
│  ┌─────────────────┐      ┌─────────────────┐                         │
│  │  Writer Instance │      │  Reader Instance │                        │
│  │  (eu-west-1a)   │      │  (eu-west-1b)   │                         │
│  │  R + W          │      │  R only         │                         │
│  └────────┬────────┘      └────────┬────────┘                         │
│           │                         │                                  │
│           └──────────┬──────────────┘                                  │
│                      ↓                                                  │
│        ┌─────────────────────────┐                                     │
│        │  Aurora Cluster Volume  │ ← almacenamiento COMPARTIDO         │
│        │  6 copias en 3 AZs     │   Las instancias leen/escriben      │
│        │  Quorum: 4/6 writes    │   del mismo storage                 │
│        │        2/6 reads       │                                      │
│        └─────────────────────────┘                                     │
│                                                                        │
│  Endpoints:                                                            │
│  • Cluster endpoint (Writer): db-lab-aurora-cluster.cluster-xxxx...   │
│  • Reader endpoint (LB):      db-lab-aurora-cluster.cluster-ro-xxxx.. │
└───────────────────────────────────────────────────────────────────────┘
```

**Diferencias clave con RDS Multi-AZ:**

| | RDS Multi-AZ | Aurora |
|--|--|--|
| Storage | Dos copias separadas (sync) | Un cluster volume compartido (6 copias) |
| Failover | ~1-2 min (DNS flip) | <30 seg |
| Reader endpoint | NO existe (standby invisible) | SÍ, balancea entre readers |
| Read Replicas | Hasta 5, storage propio | Hasta 15, storage compartido → sin lag de replicación |
| Backtrack | NO | SÍ (MySQL only) |

---

## Prerrequisitos

Reutiliza la VPC del lab01 (`vpc-db-labs`) si está disponible.

Si no, necesitas una VPC con:
- 2 subnets privadas en AZs distintas (eu-west-1a, eu-west-1b)
- Una EC2 con SSM Session Manager
- SG `sg-app-db-labs` para la EC2

> **Opción rápida:** Si tienes el lab01 activo, sáltate el paso de red y ve directo al Paso 2.

---

## Paso 1 — DB Subnet Group para Aurora

Aurora requiere subnets en **al menos 2 AZs** para poder colocar Writer y Reader en distintas zonas.

### Consola

1. **RDS → Subnet groups → Create DB subnet group**
2. Nombre: `aurora-lab-subnetgroup`
3. Descripción: `Aurora subnets for lab02`
4. VPC: `vpc-db-labs` (10.20.0.0/16)
5. Add subnets:
   - AZ `eu-west-1a` → subnet privada A (10.20.10.0/24)
   - AZ `eu-west-1b` → subnet privada B (10.20.11.0/24)
6. **Create**

<details>
<summary>CLI equivalente</summary>

```bash
SUBNET_A=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$(cat 00-resources.env | grep VPC_ID | cut -d= -f2)" \
            "Name=cidrBlock,Values=10.20.10.0/24" \
  --query 'Subnets[0].SubnetId' --output text --region eu-west-1)

SUBNET_B=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$(cat 00-resources.env | grep VPC_ID | cut -d= -f2)" \
            "Name=cidrBlock,Values=10.20.11.0/24" \
  --query 'Subnets[0].SubnetId' --output text --region eu-west-1)

aws rds create-db-subnet-group \
  --db-subnet-group-name aurora-lab-subnetgroup \
  --db-subnet-group-description "Aurora subnets for lab02" \
  --subnet-ids $SUBNET_A $SUBNET_B \
  --tags Key=Project,Value=db-labs Key=Lab,Value=lab02 \
  --region eu-west-1
```

</details>

---

## Paso 2 — Security Group para Aurora

El SG de Aurora solo necesita inbound desde `sg-app-db-labs`.

### Consola

1. **VPC → Security Groups → Create security group**
2. Nombre: `sg-aurora-db-labs`
3. VPC: `vpc-db-labs`
4. **Inbound rules → Add rule:**
   - Type: `MySQL/Aurora` (3306)
   - Source: security group `sg-app-db-labs`
5. Outbound: sin cambios (all traffic)
6. Tags: `Project=db-labs`, `Lab=lab02`
7. **Create security group**

<details>
<summary>CLI equivalente</summary>

```bash
VPC_ID=$(cat 00-resources.env | grep VPC_ID | cut -d= -f2)
SG_APP=$(cat 00-resources.env | grep SG_APP | cut -d= -f2)

SG_AURORA=$(aws ec2 create-security-group \
  --group-name sg-aurora-db-labs \
  --description "Aurora MySQL - lab02" \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=db-labs},{Key=Lab,Value=lab02}]" \
  --query 'GroupId' --output text --region eu-west-1)

aws ec2 authorize-security-group-ingress \
  --group-id $SG_AURORA \
  --protocol tcp --port 3306 \
  --source-group $SG_APP \
  --region eu-west-1

echo "SG_AURORA=$SG_AURORA" >> 00-resources-aurora.env
```

</details>

---

## Paso 3 — Secreto en Secrets Manager para Aurora

### Consola

1. **Secrets Manager → Store a new secret**
2. Secret type: **Credentials for Amazon RDS database**
3. Username: `admin`
4. Password: (genera una segura, mínimo 16 chars)
5. Encryption key: (elige el CMK de lab01 si existe, o `aws/secretsmanager`)
6. Database: **selecciona después del Paso 4** — de momento omitir
7. Nombre del secret: `lab02/aurora/admin`
8. Description: `Aurora MySQL admin credentials for lab02`
9. **No rotation** por ahora (se configura en el paso de cluster)
10. **Store**

> Anota el ARN del secret: `arn:aws:secretsmanager:eu-west-1:XXXX:secret:lab02/aurora/admin-XXXX`

<details>
<summary>CLI equivalente</summary>

```bash
AURORA_PASSWORD=$(aws secretsmanager get-random-password \
  --password-length 20 \
  --exclude-punctuation \
  --query 'RandomPassword' --output text --region eu-west-1)

SECRET_ARN=$(aws secretsmanager create-secret \
  --name lab02/aurora/admin \
  --description "Aurora MySQL admin credentials for lab02" \
  --secret-string "{\"username\":\"admin\",\"password\":\"${AURORA_PASSWORD}\"}" \
  --tags Key=Project,Value=db-labs Key=Lab,Value=lab02 \
  --query 'ARN' --output text --region eu-west-1)

echo "SECRET_AURORA_ARN=$SECRET_ARN" >> 00-resources-aurora.env
echo "Aurora password guardada en Secrets Manager: $SECRET_ARN"
```

</details>

---

## Paso 4 — Crear el Aurora MySQL Cluster

> **Importante:** En Aurora se crean DOS cosas separadas:
> 1. El **DB Cluster** (configuración, endpoints, backups, storage)
> 2. Las **DB Instances** (las instancias de compute que leen/escriben del cluster)

### Consola — Crear el Cluster

1. **RDS → Create database**
2. Creation method: **Standard create**
3. Engine type: **Amazon Aurora**
4. Edition: **Amazon Aurora MySQL-Compatible Edition**
5. Engine version: **Aurora MySQL 8.0** (elige la más reciente disponible)
6. Templates: **Dev/Test** (no Multi-AZ, ahorra coste)

### Configuración

| Campo | Valor |
|-------|-------|
| DB cluster identifier | `db-lab-aurora-cluster` |
| Master username | `admin` |
| Master password | Usa la del secret del Paso 3 |
| DB instance class | `db.t3.medium` (mínimo para Aurora) |
| Availability zone (instance) | `eu-west-1a` |

> **Nota:** Aurora no está disponible en `db.t3.micro`. El mínimo es `db.t3.medium` (~0.073€/h por instancia).

### Connectivity

| Campo | Valor |
|-------|-------|
| VPC | `vpc-db-labs` |
| DB subnet group | `aurora-lab-subnetgroup` |
| Public access | **No** |
| VPC security group | `sg-aurora-db-labs` (elimina `default`) |
| Availability zone | `eu-west-1a` |

### Additional configuration

| Campo | Valor |
|-------|-------|
| Initial database name | `auroradb` |
| Backup retention | 1 day |
| Encryption | Enable (aws/rds o CMK del lab01) |
| Backtrack | Enable (1 hora máximo en lab — para SAA!) |
| Enhanced monitoring | Enable, 60 seconds |
| Auto minor version upgrade | Disable |

### Tags

```
Project = db-labs
Lab     = lab02
Env     = lab
```

7. **Create database** — tardará ~5-8 minutos

<details>
<summary>CLI equivalente</summary>

```bash
# Obtener password del secret
AURORA_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id lab02/aurora/admin \
  --query 'SecretString' --output text --region eu-west-1 | jq -r '.password')

VPC_ID=$(cat 00-resources-aurora.env | grep VPC_ID | cut -d= -f2 2>/dev/null || cat 00-resources.env | grep VPC_ID | cut -d= -f2)
SG_AURORA=$(cat 00-resources-aurora.env | grep SG_AURORA | cut -d= -f2)

# 1. Crear el DB Cluster
aws rds create-db-cluster \
  --db-cluster-identifier db-lab-aurora-cluster \
  --engine aurora-mysql \
  --engine-version 8.0.mysql_aurora.3.04.0 \
  --master-username admin \
  --master-user-password "$AURORA_PASSWORD" \
  --db-subnet-group-name aurora-lab-subnetgroup \
  --vpc-security-group-ids $SG_AURORA \
  --database-name auroradb \
  --backup-retention-period 1 \
  --no-publicly-accessible \
  --storage-encrypted \
  --backtrack-window 3600 \
  --tags Key=Project,Value=db-labs Key=Lab,Value=lab02 Key=Env,Value=lab \
  --region eu-west-1

# 2. Crear la Writer Instance
aws rds create-db-instance \
  --db-instance-identifier db-lab-aurora-writer \
  --db-cluster-identifier db-lab-aurora-cluster \
  --engine aurora-mysql \
  --db-instance-class db.t3.medium \
  --availability-zone eu-west-1a \
  --no-publicly-accessible \
  --tags Key=Project,Value=db-labs Key=Lab,Value=lab02 \
  --region eu-west-1

# Esperar a que la instancia esté disponible
echo "Esperando Writer instance (~5-8 min)..."
aws rds wait db-instance-available \
  --db-instance-identifier db-lab-aurora-writer \
  --region eu-west-1

echo "Writer instance disponible"
```

</details>

---

## Paso 5 — Añadir Reader Instance

### Consola

1. **RDS → Databases → db-lab-aurora-cluster**
2. **Actions → Add reader**
3. DB instance identifier: `db-lab-aurora-reader`
4. Instance class: `db.t3.medium`
5. AZ: `eu-west-1b`
6. Tags: `Project=db-labs`, `Lab=lab02`
7. **Add reader** — otros ~3-5 minutos

<details>
<summary>CLI equivalente</summary>

```bash
aws rds create-db-instance \
  --db-instance-identifier db-lab-aurora-reader \
  --db-cluster-identifier db-lab-aurora-cluster \
  --engine aurora-mysql \
  --db-instance-class db.t3.medium \
  --availability-zone eu-west-1b \
  --tags Key=Project,Value=db-labs Key=Lab,Value=lab02 \
  --region eu-west-1

aws rds wait db-instance-available \
  --db-instance-identifier db-lab-aurora-reader \
  --region eu-west-1
echo "Reader instance disponible"
```

</details>

---

## Paso 6 — Obtener los endpoints y conectar

### Endpoints del cluster

```bash
# Cluster (Writer) endpoint — para INSERT/UPDATE/DELETE
aws rds describe-db-clusters \
  --db-cluster-identifier db-lab-aurora-cluster \
  --query 'DBClusters[0].{Writer:Endpoint,Reader:ReaderEndpoint,Port:Port}' \
  --output table --region eu-west-1
```

Ejemplo de salida:
```
---------------------------------------------------------------------------------------------------
| Writer: db-lab-aurora-cluster.cluster-xxxx.eu-west-1.rds.amazonaws.com           | Port: 3306 |
| Reader: db-lab-aurora-cluster.cluster-ro-xxxx.eu-west-1.rds.amazonaws.com        | Port: 3306 |
---------------------------------------------------------------------------------------------------
```

### Conectar desde la EC2 (SSM Session Manager)

```bash
# 1. Obtener password del secret
AURORA_PW=$(aws secretsmanager get-secret-value \
  --secret-id lab02/aurora/admin \
  --query 'SecretString' --output text --region eu-west-1 | jq -r '.password')

# 2. Writer endpoint (lectura + escritura)
WRITER="db-lab-aurora-cluster.cluster-xxxx.eu-west-1.rds.amazonaws.com"
mysql -h $WRITER -u admin -p"$AURORA_PW" auroradb \
  -e "SELECT @@aurora_server_id, @@read_only;"

# 3. Reader endpoint (solo lectura — load balances entre readers)
READER="db-lab-aurora-cluster.cluster-ro-xxxx.eu-west-1.rds.amazonaws.com"
mysql -h $READER -u admin -p"$AURORA_PW" auroradb \
  -e "SELECT @@aurora_server_id, @@read_only;"
```

Resultado esperado en el Writer:
```
+-----------------------+-----------+
| @@aurora_server_id    | @@read_only |
+-----------------------+-----------+
| db-lab-aurora-writer  |           0 |  ← 0 = acepta escrituras
+-----------------------+-----------+
```

Resultado esperado en el Reader:
```
+-----------------------+-----------+
| @@aurora_server_id    | @@read_only |
+-----------------------+-----------+
| db-lab-aurora-reader  |           1 |  ← 1 = solo lectura
+-----------------------+-----------+
```

---

## Paso 7 — Verificar almacenamiento compartido (no hay replication lag)

A diferencia de RDS Read Replicas, Aurora Reader lee del mismo cluster volume → no hay lag.

```sql
-- Desde la EC2, conectar al WRITER y crear datos:
mysql -h $WRITER -u admin -p"$AURORA_PW" auroradb << 'EOF'
CREATE TABLE IF NOT EXISTS aurora_test (
  id INT AUTO_INCREMENT PRIMARY KEY,
  mensaje VARCHAR(100),
  creado_en DATETIME DEFAULT NOW()
);
INSERT INTO aurora_test (mensaje) VALUES ('test desde writer 1'), ('test desde writer 2');
SELECT * FROM aurora_test;
EOF

-- Inmediatamente leer desde el READER (sin esperar):
mysql -h $READER -u admin -p"$AURORA_PW" auroradb \
  -e "SELECT * FROM aurora_test;"
```

Los datos aparecen **instantáneamente** en el Reader (mismo storage) vs RDS Read Replica donde hay lag de milisegundos.

---

## ✅ Validaciones de la fase

```bash
# 1. Cluster en estado available
aws rds describe-db-clusters \
  --db-cluster-identifier db-lab-aurora-cluster \
  --query 'DBClusters[0].{Status:Status,Engine:Engine,MultiAZ:MultiAZ}' \
  --output table --region eu-west-1
# Esperado: Status=available

# 2. Dos instancias: writer + reader
aws rds describe-db-instances \
  --filters "Name=db-cluster-id,Values=db-lab-aurora-cluster" \
  --query 'DBInstances[*].{ID:DBInstanceIdentifier,Role:ReadReplicaSourceDBInstanceIdentifier,Status:DBInstanceStatus,AZ:AvailabilityZone}' \
  --output table --region eu-west-1
# Esperado: db-lab-aurora-writer (eu-west-1a) + db-lab-aurora-reader (eu-west-1b)

# 3. Backtrack habilitado
aws rds describe-db-clusters \
  --db-cluster-identifier db-lab-aurora-cluster \
  --query 'DBClusters[0].BacktrackWindow' \
  --output text --region eu-west-1
# Esperado: 3600 (o mayor)

# 4. No publicly accessible
aws rds describe-db-instances \
  --db-instance-identifier db-lab-aurora-writer \
  --query 'DBInstances[0].PubliclyAccessible' \
  --output text --region eu-west-1
# Esperado: False
```

---

## Conceptos SAA-C03 cubiertos en esta fase

| Concepto | Evidencia en el lab |
|----------|---------------------|
| Aurora cluster volume (6 copias/3 AZs) | Reader lee sin lag del mismo storage |
| Cluster endpoint vs Reader endpoint | Paso 6: dos endpoints distintos |
| Aurora mínimo 2 instancias | Writer eu-west-1a + Reader eu-west-1b |
| Backtrack (MySQL only) | Habilitado en Paso 4 |
| No publicly accessible | Validación Paso 7 |
| Failover <30 seg | Ver Fase 02 |
