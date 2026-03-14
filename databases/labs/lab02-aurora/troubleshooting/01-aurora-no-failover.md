# Troubleshooting 01 — Aurora: el failover no ocurre o tarda demasiado

## Escenario

Ejecutas un `Reboot with Failover` o se produce un fallo de instancia, pero:
- El Writer original sigue siendo el Writer después de 2-3 minutos
- O el cluster queda en estado `failing-over` por más de 5 minutos
- O la aplicación sigue recibiendo errores aunque el cluster diga `available`

---

## Diagnóstico

### Paso 1: Verificar estado actual del cluster

```bash
aws rds describe-db-clusters \
  --db-cluster-identifier db-lab-aurora-cluster \
  --query 'DBClusters[0].{Status:Status,Members:DBClusterMembers}' \
  --output json --region eu-west-1
```

Resultado problemático:
```json
{
  "Status": "failing-over",
  "Members": [...]
}
```

Resultado correcto después del failover:
```json
{
  "Status": "available",
  "Members": [
    {"DBInstanceIdentifier": "db-lab-aurora-writer", "IsClusterWriter": false},
    {"DBInstanceIdentifier": "db-lab-aurora-reader", "IsClusterWriter": true}
  ]
}
```

### Paso 2: Verificar que hay al menos una Reader Instance

```bash
aws rds describe-db-instances \
  --filters "Name=db-cluster-id,Values=db-lab-aurora-cluster" \
  --query 'DBInstances[*].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,AZ:AvailabilityZone}' \
  --output table --region eu-west-1
```

**Si solo hay una instancia (el Writer), el failover NO puede ocurrir** — Aurora necesita al menos un Reader al que promover.

### Paso 3: Verificar Promotion Tiers

```bash
aws rds describe-db-instances \
  --filters "Name=db-cluster-id,Values=db-lab-aurora-cluster" \
  --query 'DBInstances[*].{ID:DBInstanceIdentifier,Tier:PromotionTier,Status:DBInstanceStatus}' \
  --output table --region eu-west-1
```

Si todos los Readers tienen `Tier=15` (el valor más bajo de prioridad), el failover puede ser más lento o impredecible.

### Paso 4: Verificar Events del cluster

```bash
aws rds describe-events \
  --source-identifier db-lab-aurora-cluster \
  --source-type db-cluster \
  --duration 60 \
  --region eu-west-1
```

Busca eventos como:
- `Failover started for DB cluster`
- `Multi-AZ instance failover completed`
- `A new writer was selected`

---

## Causas y soluciones

### Causa 1 — Sin Reader Instance para promover

**Síntoma:** Solo hay una instancia en el cluster.

**Fix:** Añadir una Reader Instance:

```bash
aws rds create-db-instance \
  --db-instance-identifier db-lab-aurora-reader \
  --db-cluster-identifier db-lab-aurora-cluster \
  --engine aurora-mysql \
  --db-instance-class db.t3.medium \
  --availability-zone eu-west-1b \
  --region eu-west-1

aws rds wait db-instance-available \
  --db-instance-identifier db-lab-aurora-reader \
  --region eu-west-1
```

### Causa 2 — Todos los Readers en tier-15 (baja prioridad)

**Fix:** Subir la prioridad del Reader preferido:

```bash
aws rds modify-db-instance \
  --db-instance-identifier db-lab-aurora-reader \
  --promotion-tier 0 \
  --apply-immediately \
  --region eu-west-1
```

### Causa 3 — Reader en estado no-available (creating, modifying, etc.)

Si el Reader está en un estado que no es `available`, no puede ser promovido.

```bash
# Ver el estado actual
aws rds describe-db-instances \
  --db-instance-identifier db-lab-aurora-reader \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text --region eu-west-1

# Esperar a que esté available
aws rds wait db-instance-available \
  --db-instance-identifier db-lab-aurora-reader \
  --region eu-west-1
```

### Causa 4 — La aplicación no renegocia la conexión TCP

Después del failover, el cluster endpoint DNS apunta al nuevo Writer. Sin embargo, si la aplicación mantiene una conexión TCP abierta (persistente), **esa conexión ya cayó** y la app necesita reconectar.

**Síntoma:** Aurora dice `available` y el nuevo Writer está correcto, pero la app sigue fallando.

**Fix en la aplicación:**

```python
# Usar conexión con retry y timeout de TCP corto
import pymysql
from pymysql import OperationalError
import time

def get_connection(host, retries=3):
    for attempt in range(retries):
        try:
            conn = pymysql.connect(
                host=host,
                port=3306,
                connect_timeout=5,    # Timeout de conexión
                read_timeout=30,       # Timeout de lectura
                write_timeout=30,
            )
            return conn
        except OperationalError as e:
            if attempt < retries - 1:
                time.sleep(2 ** attempt)  # backoff exponencial
            else:
                raise
```

---

## Prevención

1. **Siempre tener al menos una Reader Instance** en clusters de producción.
2. **Configurar promotion_tier=0** en el Reader preferido para failover predecible.
3. **Implementar retry logic** en la capa de aplicación (aurora_writer_endpoint puede cambiar de instancia).
4. **Usar RDS Proxy** (lab05) para absorber reconexiones durante failover sin cambios en la app.

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|----------|-----------|
| ¿Sin Reader, puede ocurrir el failover? | **NO** — necesita Reader para promover |
| ¿Qué promotion_tier garantiza que el Reader sea promovido primero? | **Tier-0** |
| ¿Cuánto tarda el failover Aurora si hay Reader disponible? | **<30 segundos** |
| ¿Cambia el cluster endpoint tras el failover? | **NO** — el CNAME se actualiza automáticamente |
