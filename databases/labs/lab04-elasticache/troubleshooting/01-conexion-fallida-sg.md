# Troubleshooting 01 — ElastiCache: No se puede conectar a Redis

## Escenario

Desde la EC2, ejecutas:
```bash
redis-cli -h redis-lab-cluster.xxxxxx.ng.0001.euw1.cache.amazonaws.com -p 6379 --tls PING
```

Y obtienes:
```
Could not connect to Redis at ...:6379: Connection timed out
```

O el intento se queda colgado sin respuesta.

---

## Diagnóstico

### Paso 1: Test de conectividad TCP

```bash
# Desde la EC2, verificar que el puerto 6379 está accesible
NC_HOST="redis-lab-cluster.xxxxxx.ng.0001.euw1.cache.amazonaws.com"
nc -zv $NC_HOST 6379

# Si timeout → problema de SG o VPC
# Si "succeeded" → problema de configuración de redis-cli (TLS, auth)
```

### Paso 2: Verificar el Security Group de Redis

```bash
# Ver qué SG tiene el Replication Group
aws elasticache describe-replication-groups \
  --replication-group-id redis-lab-cluster \
  --query 'ReplicationGroups[0].SecurityGroups' \
  --output table --region eu-west-1

# Obtener el SG ID
SG_REDIS="sg-xxxxxxxxx"

# Ver las reglas inbound del SG de Redis
aws ec2 describe-security-groups \
  --group-ids $SG_REDIS \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json --region eu-west-1
```

Deberías ver:
```json
[{
  "FromPort": 6379,
  "ToPort": 6379,
  "IpProtocol": "tcp",
  "UserIdGroupPairs": [{"GroupId": "sg-app-xxxx"}]
}]
```

Si no hay ninguna regla inbound en el puerto 6379 → es el problema.

### Paso 3: Verificar que la EC2 usa el SG correcto

```bash
# Ver SG de la EC2
EC2_ID="i-xxxxxxxxx"
aws ec2 describe-instances \
  --instance-ids $EC2_ID \
  --query 'Reservations[0].Instances[0].SecurityGroups' \
  --output table --region eu-west-1
# Debe incluir sg-app-db-labs
```

### Paso 4: Verificar que están en la misma VPC

```bash
# VPC de Redis
REDIS_VPC=$(aws elasticache describe-cache-subnet-groups \
  --cache-subnet-group-name redis-lab-subnetgroup \
  --query 'CacheSubnetGroups[0].VpcId' \
  --output text --region eu-west-1)

# VPC de la EC2
EC2_VPC=$(aws ec2 describe-instances \
  --instance-ids $EC2_ID \
  --query 'Reservations[0].Instances[0].VpcId' \
  --output text --region eu-west-1)

echo "Redis VPC: $REDIS_VPC"
echo "EC2 VPC:   $EC2_VPC"
[[ "$REDIS_VPC" == "$EC2_VPC" ]] && echo "✓ Misma VPC" || echo "✗ VPCs distintas — el tráfico no puede fluir"
```

---

## Causas y soluciones

### Causa 1 — Regla inbound faltante en el SG de Redis (la más común)

**Fix:**

```bash
# Obtener el SG de la EC2 (sg-app-db-labs)
SG_APP=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=sg-app-db-labs" \
  --query 'SecurityGroups[0].GroupId' \
  --output text --region eu-west-1)

# Añadir la regla inbound
aws ec2 authorize-security-group-ingress \
  --group-id $SG_REDIS \
  --protocol tcp \
  --port 6379 \
  --source-group $SG_APP \
  --region eu-west-1
```

### Causa 2 — EC2 no tiene el SG correcto

Si la EC2 usa un SG diferente a `sg-app-db-labs`, la regla inbound de Redis no la permite.

**Fix opción A — Añadir el SG de la EC2 a la regla de Redis:**

```bash
# Obtener SG actual de la EC2
EC2_SG=$(aws ec2 describe-instances \
  --instance-ids $EC2_ID \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
  --output text --region eu-west-1)

aws ec2 authorize-security-group-ingress \
  --group-id $SG_REDIS \
  --protocol tcp --port 6379 \
  --source-group $EC2_SG \
  --region eu-west-1
```

**Fix opción B — Añadir `sg-app-db-labs` a la EC2:**

```bash
aws ec2 modify-instance-attribute \
  --instance-id $EC2_ID \
  --groups $EC2_SG $SG_APP \
  --region eu-west-1
```

### Causa 3 — TLS habilitado pero redis-cli sin `--tls`

Si el Replication Group tiene `TransitEncryptionEnabled=true`, debes usar `--tls`:

```bash
# Sin TLS (falla si transit encryption está habilitado)
redis-cli -h $REDIS_HOST -p 6379 PING
# Error: "ERR Unencrypted connection is not allowed"

# Con TLS (correcto)
redis-cli -h $REDIS_HOST -p 6379 --tls PING
```

### Causa 4 — Redis en subnet pública (sin acceso desde subnets privadas)

Si Redis está en subnets públicas y la EC2 en subnets privadas (o viceversa), el routing puede fallar.

```bash
# Verificar subnets del Subnet Group
aws elasticache describe-cache-subnet-groups \
  --cache-subnet-group-name redis-lab-subnetgroup \
  --query 'CacheSubnetGroups[0].Subnets[*].{AZ:SubnetAvailabilityZone.Name,ID:SubnetIdentifier}' \
  --output table --region eu-west-1
```

**Fix:** Asegúrate de que el Subnet Group use subnets privadas (10.20.10.0/24, 10.20.11.0/24) y que exista una ruta entre EC2 y Redis (misma VPC, subnets privadas).

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|----------|-----------|
| ¿ElastiCache tiene IP pública? | **No** — solo accesible desde dentro de la VPC |
| ¿Cómo controlar el acceso a Redis? | Security Groups (no NACL es suficiente) |
| ¿ElastiCache soporta autenticación? | Redis ≥ 6: AUTH token o Redis ACL |
| ¿Se puede acceder desde otra VPC? | Con VPC Peering o Transit Gateway |
