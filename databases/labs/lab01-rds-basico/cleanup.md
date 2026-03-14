# Cleanup — Lab 01 RDS MySQL

> ⚠️ **Coste si se olvida activo:** ~0.08€/hora (RDS + replica + EC2) + ~0.045€/hora (NAT Gateway)
> Con Read Replica y Multi-AZ activos: ~0.22€/hora → **~160€/mes** si se olvida.

---

## Opción rápida: Script automatizado

```bash
bash cli/99-cleanup.sh
```

El script te pide confirmación y elimina todo en el orden correcto.

---

## Opción manual: Orden de eliminación (IMPORTANTE)

El orden importa porque hay dependencias entre recursos. Si borras en orden incorrecto, AWS te dará errores de "resource in use" o "dependencies exist".

### 1. Read Replica

**Consola:** RDS → Databases → `db-lab-rds-replica` → Actions → **Delete**
- Final snapshot: `No` (lab)
- Retener automated backups: `No`

> ⏳ Esperar ~5 min hasta que desaparezca de la lista.

### 2. RDS Primary

**Consola:** RDS → `db-lab-rds-instance` → Actions → **Delete**
- Final snapshot: `No` (lab)
- Retener automated backups: `No`
- Delete automated backups: `Yes`

> ⏳ Esperar ~10 min. El standby de Multi-AZ se elimina automáticamente.

### 3. Secrets Manager

**Consola:** Secrets Manager → `db-lab-rds-credentials` → Actions → **Delete secret**
- Waiting period: **7 days** (mínimo) o clic en "Schedule deletion with no waiting period" (solo disponible en CLI)

```bash
# Eliminar inmediatamente (sin periodo de espera)
aws secretsmanager delete-secret \
  --secret-id db-lab-rds-credentials \
  --force-delete-without-recovery \
  --region eu-west-1
```

### 4. DB Subnet Group

**Consola:** RDS → Subnet groups → `db-lab-rds-subnetgroup` → **Delete**

> ⚠️ Solo se puede borrar si no hay instancias RDS usando el grupo.

### 5. CloudWatch Alarms

**Consola:** CloudWatch → Alarms → seleccionar las 3 alarms del lab → **Delete**
- `db-lab-rds-storage-low`
- `db-lab-rds-cpu-high`
- `db-lab-rds-replica-lag`

### 6. CloudWatch Log Groups

**Consola:** CloudWatch → Log Groups → buscar `/aws/rds/instance/db-lab-rds-*` → **Delete**

### 7. EC2 instance

**Consola:** EC2 → Instances → `db-lab-rds-app` → Instance state → **Terminate**

> ⏳ Esperar hasta estado `Terminated`.

### 8. VPC Endpoints SSM

**Consola:** VPC → Endpoints → filtrar por `vpc-db-labs` → seleccionar los 3 → **Delete**
- ep-ssm, ep-ssmmessages, ep-ec2messages

### 9. IAM Role + Instance Profile

**Consola:** IAM → Roles → `role-ec2-ssm-db-labs`
1. Detach todas las policies adjuntas
2. Delete role

### 10. NAT Gateway

**Consola:** VPC → NAT Gateways → `nat-db-labs` → **Delete**

> ⏳ Esperar hasta estado `Deleted` (~2 min).

### 11. Elastic IP

**Consola:** EC2 → Elastic IPs → seleccionar la EIP sin asociar → **Release Elastic IP address**

> ⚠️ Si no liberas la EIP, sigue generando coste aunque no esté asociada.

### 12. Internet Gateway

**Consola:** VPC → Internet Gateways → `igw-db-labs`
1. Actions → **Detach from VPC**
2. Actions → **Delete internet gateway**

### 13. Route Tables (custom)

**Consola:** VPC → Route Tables → filtrar por `vpc-db-labs`
- Seleccionar `rt-public-db-labs` y `rt-private-db-labs`
- Subnet associations → Edit → desmarcar todas las subnets → Save
- **Delete route table** para cada una

> La route table `main` (creada automáticamente) se elimina con la VPC.

### 14. Subnets

**Consola:** VPC → Subnets → filtrar por `vpc-db-labs` → seleccionar las 5 → **Delete**

### 15. Security Groups

**Consola:** VPC → Security Groups → filtrar por `vpc-db-labs` → eliminar en este orden:
1. `sg-rds-db-labs` (tiene regla que referencia sg-app)
2. `sg-ssm-ep-db-labs`
3. `sg-app-db-labs`

> El SG default de la VPC se elimina automáticamente con la VPC.

### 16. VPC

**Consola:** VPC → Your VPCs → `vpc-db-labs` → **Delete VPC**

> ⚠️ Solo funciona si todos los recursos anteriores están eliminados.

### 17. KMS Key

**Consola:** KMS → Customer managed keys → `alias/db-lab-rds-key`
- Key actions → **Schedule key deletion**
- Waiting period: 7 days (mínimo)

> **No se puede eliminar inmediatamente.** La clave queda en estado `Pending deletion` por 7-30 días.
> Para cancelar: Key actions → **Cancel key deletion**
> Coste durante pending deletion: 0 (no se factura una clave en ese estado)

---

## Verificación post-cleanup

```bash
# Verificar que no quedan instancias RDS
aws rds describe-db-instances --region eu-west-1 \
  --query 'DBInstances[*].{ID:DBInstanceIdentifier,Status:DBInstanceStatus}' \
  --output table

# Verificar que no quedan VPCs del lab
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=db-labs" \
  --query 'Vpcs[*].{ID:VpcId,CIDR:CidrBlock,Name:Tags[?Key==`Name`].Value|[0]}' \
  --region eu-west-1 --output table

# Verificar NAT Gateways (los más caros)
aws ec2 describe-nat-gateways \
  --filter "Name=tag:Project,Values=db-labs" \
  --query 'NatGateways[?State!=`deleted`].{ID:NatGatewayId,State:State}' \
  --region eu-west-1 --output table
```

Si todos los comandos devuelven listas vacías, el lab está limpio.
