# Cleanup — Lab04 ElastiCache Redis

> **Coste si olvidas limpiar:** ~0.034 USD/h × 2 nodos = ~0.07 USD/h = ~50 USD/mes.

---

## Recursos creados

| Recurso | Nombre |
|---------|--------|
| Replication Group | `redis-lab-cluster` |
| Cache Subnet Group | `redis-lab-subnetgroup` |
| Security Group | `sg-redis-db-labs` |

---

## Pasos en consola

### 1. Eliminar Replication Group

1. **ElastiCache → Redis OSS caches**
2. Selecciona `redis-lab-cluster`
3. **Actions → Delete**
4. ☐ Create final backup → desmarca (lab)
5. **Delete**
6. Espera ~2-3 min

### 2. Eliminar Cache Subnet Group

1. **ElastiCache → Subnet groups**
2. Selecciona `redis-lab-subnetgroup`
3. **Delete** → confirma

### 3. Eliminar Security Group

1. **VPC → Security Groups**
2. Selecciona `sg-redis-db-labs`
3. **Actions → Delete security groups**

---

## Cleanup vía CLI

```bash
set -euo pipefail
AWS_REGION="eu-west-1"

echo "=== Cleanup ElastiCache Redis Lab04 ==="
echo "¿Confirmar? (yes/no)"
read -r CONFIRM
[[ "$CONFIRM" != "yes" ]] && { echo "Cancelado."; exit 0; }

# 1. Eliminar Replication Group
echo "[1/3] Eliminando Replication Group..."
aws elasticache delete-replication-group \
  --replication-group-id redis-lab-cluster \
  --no-retain-primary-cluster \
  --region $AWS_REGION 2>/dev/null && echo "  Eliminando..." || echo "  No encontrado"

echo "  Esperando (~3-5 min)..."
aws elasticache wait replication-group-deleted \
  --replication-group-id redis-lab-cluster \
  --region $AWS_REGION 2>/dev/null && echo "  Eliminado" || echo "  Timeout"

# 2. Subnet Group
echo "[2/3] Eliminando Cache Subnet Group..."
aws elasticache delete-cache-subnet-group \
  --cache-subnet-group-name redis-lab-subnetgroup \
  --region $AWS_REGION 2>/dev/null && echo "  Eliminado" || echo "  No encontrado"

# 3. Security Group
echo "[3/3] Eliminando Security Group..."
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=sg-redis-db-labs" \
  --query 'SecurityGroups[0].GroupId' \
  --output text --region $AWS_REGION 2>/dev/null || echo "None")

[[ "$SG_ID" != "None" ]] && \
  aws ec2 delete-security-group --group-id $SG_ID --region $AWS_REGION \
    && echo "  SG eliminado" || echo "  SG: no se pudo eliminar"

echo "=== Cleanup Lab04 completado ==="
```

---

## Verificación post-cleanup

```bash
aws elasticache describe-replication-groups \
  --replication-group-id redis-lab-cluster --region eu-west-1 2>&1 \
  | grep -i "not found\|ReplicationGroupNotFoundFault"
# Esperado: error not found
```
