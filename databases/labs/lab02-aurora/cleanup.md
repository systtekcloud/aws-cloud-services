# Cleanup — Lab02 Aurora

> **Coste si olvidas limpiar:** ~0.15€/hora por instancia × 2 instancias = ~0.30€/hora = ~215€/mes.
> Limpia siempre al acabar el lab.

---

## Orden de eliminación (obligatorio)

Aurora tiene dependencias: las instancias deben eliminarse **antes** que el cluster.

```
Reader Instance → Writer Instance → DB Cluster → Subnet Group → SG → Secrets Manager
```

---

## Pasos en consola

### 1. Eliminar Reader Instance

1. **RDS → Databases**
2. Selecciona `db-lab-aurora-reader`
3. **Actions → Delete**
4. ☐ **Create final snapshot** → desmarca (lab)
5. ☑ **I acknowledge...** → marca
6. Escribe `delete me` y confirma

Espera a que desaparezca (~3-5 min).

### 2. Eliminar Writer Instance

1. Selecciona `db-lab-aurora-writer`
2. **Actions → Delete**
3. ☐ Create final snapshot → desmarca
4. ☑ acknowledge → marca
5. `delete me` → confirma

Espera a que desaparezca.

### 3. Eliminar el DB Cluster

Una vez que ambas instancias se eliminaron, el cluster aparece sin instancias:

1. Selecciona `db-lab-aurora-cluster`
2. **Actions → Delete**
3. ☐ Create final snapshot
4. ☐ Retain automated backups
5. ☑ I acknowledge...
6. `delete me` → confirma

### 4. Eliminar DB Subnet Group

1. **RDS → Subnet groups**
2. Selecciona `aurora-lab-subnetgroup`
3. **Delete** → confirma

### 5. Eliminar Security Group

1. **VPC → Security Groups**
2. Selecciona `sg-aurora-db-labs`
3. **Actions → Delete security groups** → confirma

### 6. Eliminar Secret en Secrets Manager

1. **Secrets Manager → Secrets**
2. Selecciona `lab02/aurora/admin`
3. **Actions → Delete secret**
4. Recovery window: **0 days** (eliminar inmediatamente para el lab)
5. **Schedule deletion**

---

## Cleanup vía CLI

```bash
# ============================================================
# AURORA CLEANUP SCRIPT — lab02
# ============================================================

set -euo pipefail

echo "=== Iniciando cleanup Aurora lab02 ==="
echo "ATENCIÓN: Esto eliminará todos los recursos de Aurora. ¿Continuar? (yes/no)"
read -r CONFIRM
[[ "$CONFIRM" != "yes" ]] && { echo "Cancelado."; exit 0; }

# ---- Paso 1: Eliminar Reader ----
echo "[1/6] Eliminando Reader Instance..."
aws rds delete-db-instance \
  --db-instance-identifier db-lab-aurora-reader \
  --skip-final-snapshot \
  --region eu-west-1 2>/dev/null && echo "  Reader: eliminando..." || echo "  Reader: no encontrado"

# ---- Paso 2: Eliminar Writer ----
echo "[2/6] Eliminando Writer Instance..."
aws rds delete-db-instance \
  --db-instance-identifier db-lab-aurora-writer \
  --skip-final-snapshot \
  --region eu-west-1 2>/dev/null && echo "  Writer: eliminando..." || echo "  Writer: no encontrado"

# Esperar a que ambas instancias desaparezcan
echo "  Esperando que las instancias terminen (~5-10 min)..."
for INSTANCE in db-lab-aurora-writer db-lab-aurora-reader; do
  while aws rds describe-db-instances \
    --db-instance-identifier $INSTANCE \
    --region eu-west-1 &>/dev/null; do
    echo -n "."
    sleep 15
  done
done
echo " OK"

# ---- Paso 3: Eliminar Cluster ----
echo "[3/6] Eliminando DB Cluster..."
aws rds delete-db-cluster \
  --db-cluster-identifier db-lab-aurora-cluster \
  --skip-final-snapshot \
  --region eu-west-1 2>/dev/null && echo "  Cluster: eliminado" || echo "  Cluster: no encontrado"

# ---- Paso 4: DB Subnet Group ----
echo "[4/6] Eliminando DB Subnet Group..."
aws rds delete-db-subnet-group \
  --db-subnet-group-name aurora-lab-subnetgroup \
  --region eu-west-1 2>/dev/null && echo "  Subnet group: eliminado" || echo "  Subnet group: no encontrado"

# ---- Paso 5: Security Group ----
echo "[5/6] Eliminando Security Group..."
SG_AURORA=$(cat 00-resources-aurora.env 2>/dev/null | grep SG_AURORA | cut -d= -f2 || echo "")
if [[ -n "$SG_AURORA" ]]; then
  aws ec2 delete-security-group --group-id $SG_AURORA --region eu-west-1 \
    && echo "  SG: eliminado" || echo "  SG: no se pudo eliminar (puede estar en uso)"
else
  echo "  SG: ID no encontrado en 00-resources-aurora.env"
fi

# ---- Paso 6: Secrets Manager ----
echo "[6/6] Eliminando secret de Aurora..."
aws secretsmanager delete-secret \
  --secret-id lab02/aurora/admin \
  --force-delete-without-recovery \
  --region eu-west-1 2>/dev/null && echo "  Secret: eliminado" || echo "  Secret: no encontrado"

echo ""
echo "=== Cleanup completado ==="
echo "Verifica en la consola que no queden recursos de Aurora activos."
```

---

## Verificación post-cleanup

```bash
# 1. Sin instancias Aurora
aws rds describe-db-instances \
  --filters "Name=db-cluster-id,Values=db-lab-aurora-cluster" \
  --query 'DBInstances[*].DBInstanceIdentifier' \
  --output text --region eu-west-1
# Esperado: (vacío o error "DBClusterNotFoundFault")

# 2. Sin cluster
aws rds describe-db-clusters \
  --db-cluster-identifier db-lab-aurora-cluster \
  --region eu-west-1 2>&1 | grep -i "not found\|DBClusterNotFoundFault"
# Esperado: error "not found"

# 3. Sin subnet group
aws rds describe-db-subnet-groups \
  --db-subnet-group-name aurora-lab-subnetgroup \
  --region eu-west-1 2>&1 | grep -i "not found"

# 4. Coste: CloudWatch Cost Explorer
# Comprueba que no aparecen cargos de RDS tras el cleanup
```

---

## Si también limpias el lab01 (VPC compartida)

Si tienes el lab01 activo y también quieres limpiar la red:

1. Primero limpia lab02 (este doc)
2. Luego sigue `lab01-rds-basico/cleanup.md` para la VPC, subnets y SSM endpoints
3. O usa `lab01-rds-basico/cli/99-cleanup.sh`
