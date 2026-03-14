# Fase 01 — ElastiCache Redis: Cluster Setup y Conectividad

## Objetivo

Crear un Replication Group de ElastiCache Redis con un Primary y un Replica, conectar desde la EC2 usando redis-cli, y verificar la replicación automática.

**Tiempo estimado:** 30-35 minutos
**Coste:** ~0.034€/hora por nodo `cache.t3.micro` = ~0.07€/hora total (primary + replica)

---

## Conceptos antes de empezar

```
┌───────────────────────────────────────────────────────────────────────┐
│  ELASTICACHE REDIS — REPLICATION GROUP                                 │
│                                                                        │
│  Primary Node (eu-west-1a)          Replica Node (eu-west-1b)         │
│  ┌─────────────────────┐            ┌─────────────────────┐           │
│  │  R + W              │ ──async──► │  R only             │           │
│  │  Primary Endpoint   │            │  Reader Endpoint     │           │
│  └─────────────────────┘            └─────────────────────┘           │
│                                                                        │
│  • Primary Endpoint → escritura (automáticamente al Primary)          │
│  • Reader Endpoint → lectura (balancea entre replica(s))              │
│  • Failover: si el Primary cae, la Replica se promueve automáticamente│
└───────────────────────────────────────────────────────────────────────┘
```

### Redis vs Memcached — La pregunta más frecuente del examen

| Característica | Redis | Memcached |
|----------------|-------|-----------|
| Persistencia (RDB/AOF) | ✅ Sí | ❌ No |
| Replicación | ✅ Sí | ❌ No |
| Failover automático | ✅ Sí | ❌ No |
| Multi-AZ | ✅ Sí | ❌ No (multi-node, no multi-AZ) |
| Sorted Sets, HyperLogLog | ✅ Sí | ❌ No |
| Multi-thread | ❌ No (single thread) | ✅ Sí |
| Pub/Sub | ✅ Sí | ❌ No |
| Lua scripting | ✅ Sí | ❌ No |
| **¿Cuándo usar?** | HA, Streams, Sesiones, Leaderboards | Cache simple, máximo throughput, escala horizontal sencilla |

> **Regla de oro para el examen:** Si la pregunta menciona HA, failover, persistencia, datos complejos → Redis. Si menciona simplemente "caché de objetos sin estado" y "máximo rendimiento multi-thread" → considera Memcached.

---

## Paso 1 — Subnet Group para ElastiCache

### Consola

1. **ElastiCache → Subnet groups → Create subnet group**
2. Name: `redis-lab-subnetgroup`
3. Description: `Redis subnets for lab04`
4. VPC: `vpc-db-labs` (10.20.0.0/16)
5. Add subnets:
   - `eu-west-1a` → subnet privada A (10.20.10.0/24)
   - `eu-west-1b` → subnet privada B (10.20.11.0/24)
6. **Create**

<details>
<summary>CLI equivalente</summary>

```bash
# Obtener IDs de subnets
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=cidr,Values=10.20.0.0/16" "Name=tag:Project,Values=db-labs" \
  --query 'Vpcs[0].VpcId' --output text --region eu-west-1)

SUBNET_A=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidrBlock,Values=10.20.10.0/24" \
  --query 'Subnets[0].SubnetId' --output text --region eu-west-1)

SUBNET_B=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidrBlock,Values=10.20.11.0/24" \
  --query 'Subnets[0].SubnetId' --output text --region eu-west-1)

aws elasticache create-cache-subnet-group \
  --cache-subnet-group-name redis-lab-subnetgroup \
  --cache-subnet-group-description "Redis subnets for lab04 - private only" \
  --subnet-ids $SUBNET_A $SUBNET_B \
  --tags Key=Project,Value=db-labs Key=Lab,Value=lab04 \
  --region eu-west-1
```

</details>

---

## Paso 2 — Security Group para Redis

### Consola

1. **VPC → Security Groups → Create security group**
2. Nombre: `sg-redis-db-labs`
3. VPC: `vpc-db-labs`
4. Inbound: TCP 6379 desde `sg-app-db-labs`
5. Tags: `Project=db-labs`, `Lab=lab04`
6. **Create**

<details>
<summary>CLI equivalente</summary>

```bash
SG_APP=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=sg-app-db-labs" \
  --query 'SecurityGroups[0].GroupId' --output text --region eu-west-1)

SG_REDIS=$(aws ec2 create-security-group \
  --group-name sg-redis-db-labs \
  --description "ElastiCache Redis lab04 - inbound from sg-app only" \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=db-labs},{Key=Lab,Value=lab04}]" \
  --query 'GroupId' --output text --region eu-west-1)

aws ec2 authorize-security-group-ingress \
  --group-id $SG_REDIS \
  --protocol tcp --port 6379 \
  --source-group $SG_APP \
  --region eu-west-1

echo "SG Redis: $SG_REDIS"
```

</details>

---

## Paso 3 — Crear el Replication Group Redis

### Consola

1. **ElastiCache → Redis OSS caches → Create Redis OSS cache**
2. Design your own cache: **Cluster cache**
3. Cluster mode: **Disabled** (para este lab — un shard con réplicas)
4. Name: `redis-lab-cluster`

### Cluster settings

| Campo | Valor |
|-------|-------|
| Engine version | Redis 7.x (latest) |
| Port | 6379 |
| Parameter group | default.redis7 |
| Node type | `cache.t3.micro` (lab — ~0.034 USD/h) |
| Number of replicas | 1 |

### Connectivity

| Campo | Valor |
|-------|-------|
| Subnet group | `redis-lab-subnetgroup` |
| Availability Zones | Primary: eu-west-1a, Replica: eu-west-1b |

### Advanced settings

| Campo | Valor |
|-------|-------|
| Multi-AZ | Enabled ✅ |
| Auto-failover | Enabled ✅ |
| Encryption at rest | Enabled ✅ |
| Encryption in transit | Enabled ✅ (TLS) |
| Security groups | `sg-redis-db-labs` |

### Tags
```
Project = db-labs
Lab     = lab04
Env     = lab
```

5. **Create** — tardará ~5-8 minutos

<details>
<summary>CLI equivalente</summary>

```bash
aws elasticache create-replication-group \
  --replication-group-id redis-lab-cluster \
  --replication-group-description "Redis lab04 - cache aside y sessions" \
  --engine redis \
  --engine-version 7.1 \
  --cache-node-type cache.t3.micro \
  --num-cache-clusters 2 \
  --cache-subnet-group-name redis-lab-subnetgroup \
  --security-group-ids $SG_REDIS \
  --automatic-failover-enabled \
  --multi-az-enabled \
  --at-rest-encryption-enabled \
  --transit-encryption-enabled \
  --tags Key=Project,Value=db-labs Key=Lab,Value=lab04 Key=Env,Value=lab \
  --region eu-west-1

echo "Esperando que el cluster esté disponible (~5-8 min)..."
aws elasticache wait replication-group-available \
  --replication-group-id redis-lab-cluster \
  --region eu-west-1
echo "Redis cluster disponible"
```

</details>

---

## Paso 4 — Obtener los endpoints y conectar

```bash
# Obtener endpoints
aws elasticache describe-replication-groups \
  --replication-group-id redis-lab-cluster \
  --query 'ReplicationGroups[0].{
    Primary:NodeGroups[0].PrimaryEndpoint.Address,
    Reader:NodeGroups[0].ReaderEndpoint.Address,
    Port:NodeGroups[0].PrimaryEndpoint.Port
  }' \
  --output table --region eu-west-1
```

Ejemplo de salida:
```
Primary: redis-lab-cluster.xxxxxx.ng.0001.euw1.cache.amazonaws.com
Reader:  redis-lab-cluster-ro.xxxxxx.ng.0001.euw1.cache.amazonaws.com
Port:    6379
```

### Conectar desde la EC2 (SSM Session Manager)

```bash
# En la EC2 (via SSM)
# Instalar redis-cli si no está disponible
sudo apt-get install -y redis-tools

PRIMARY="redis-lab-cluster.xxxxxx.ng.0001.euw1.cache.amazonaws.com"

# Conectar con TLS habilitado
redis-cli -h $PRIMARY -p 6379 --tls

# O sin TLS (si lo deshabilitaste)
redis-cli -h $PRIMARY -p 6379
```

### Comandos básicos de verificación

```bash
# Ping
redis-cli -h $PRIMARY -p 6379 --tls PING
# Respuesta: PONG

# Info del servidor
redis-cli -h $PRIMARY -p 6379 --tls INFO server | grep redis_version

# Verificar rol
redis-cli -h $PRIMARY -p 6379 --tls INFO replication | grep role
# role:master  ← es el Primary

# Verificar que la réplica aparece
redis-cli -h $PRIMARY -p 6379 --tls INFO replication | grep connected_slaves
# connected_slaves:1
```

---

## Paso 5 — Verificar replicación

```bash
READER="redis-lab-cluster-ro.xxxxxx.ng.0001.euw1.cache.amazonaws.com"

# Escribir en el Primary
redis-cli -h $PRIMARY -p 6379 --tls SET test:key "hola desde primary"
# OK

# Leer desde la Replica (Reader endpoint)
redis-cli -h $READER -p 6379 --tls GET test:key
# "hola desde primary"  ← replicado automáticamente

# La réplica NO acepta escrituras
redis-cli -h $READER -p 6379 --tls SET test:otro "valor"
# READONLY You can't write against a read only replica
```

---

## ✅ Validaciones de la fase

```bash
# 1. Replication Group available
aws elasticache describe-replication-groups \
  --replication-group-id redis-lab-cluster \
  --query 'ReplicationGroups[0].{Status:Status,MultiAZ:MultiAZ,AutoFailover:AutomaticFailover}' \
  --output table --region eu-west-1
# Status=available, MultiAZ=enabled, AutomaticFailover=enabled

# 2. Dos nodos (primary + replica)
aws elasticache describe-replication-groups \
  --replication-group-id redis-lab-cluster \
  --query 'ReplicationGroups[0].MemberClusters' \
  --output table --region eu-west-1
# Debe mostrar 2 clusters

# 3. Encryption habilitado
aws elasticache describe-replication-groups \
  --replication-group-id redis-lab-cluster \
  --query 'ReplicationGroups[0].{AtRest:AtRestEncryptionEnabled,Transit:TransitEncryptionEnabled}' \
  --output table --region eu-west-1
# AtRest=true, Transit=true
```

---

## Conceptos SAA-C03 cubiertos

| Concepto | Evidencia en el lab |
|----------|---------------------|
| Replication Group Redis | Primary + Replica en AZs distintas |
| Primary endpoint vs Reader endpoint | Paso 4: dos endpoints distintos |
| Réplica = read-only | SET en Reader → READONLY error |
| Multi-AZ + Auto-failover | Configurado en el paso 3 |
| TLS en tránsito | redis-cli con `--tls` |
