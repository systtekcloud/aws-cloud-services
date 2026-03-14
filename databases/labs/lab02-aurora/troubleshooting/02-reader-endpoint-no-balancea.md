# Troubleshooting 02 — Reader Endpoint no distribuye tráfico entre readers

## Escenario

Tienes varios Aurora Reader Instances, pero al monitorizar las conexiones:
- Todo el tráfico de lectura va al mismo Reader
- O el reader endpoint siempre resuelve a la misma IP
- O un Reader tiene CPU al 80% mientras los demás están al 5%

---

## Diagnóstico

### Paso 1: Verificar el Reader Endpoint

```bash
# Obtener el endpoint de lecturas (cluster-ro-XXXX)
aws rds describe-db-clusters \
  --db-cluster-identifier db-lab-aurora-cluster \
  --query 'DBClusters[0].{Writer:Endpoint,Reader:ReaderEndpoint}' \
  --output table --region eu-west-1
```

El Reader endpoint tiene el formato:
- `db-lab-aurora-cluster.cluster-ro-xxxx.eu-west-1.rds.amazonaws.com`

Nota la diferencia con el Writer:
- Writer: `...cluster-xxxx...` (sin `-ro-`)
- Reader: `...cluster-ro-xxxx...` (con `-ro-`)

### Paso 2: Verificar que se usa el Reader Endpoint (no el Writer)

**Error común:** la aplicación usa el Writer endpoint para todas las operaciones, incluidas las lecturas.

```bash
# Desde EC2 — ver a qué instancia resuelve el reader endpoint
READER="db-lab-aurora-cluster.cluster-ro-xxxx.eu-west-1.rds.amazonaws.com"
PASS=$(aws secretsmanager get-secret-value --secret-id lab02/aurora/admin --query SecretString --output text | jq -r '.password')

# Conectar múltiples veces y ver qué servidor responde
for i in {1..5}; do
  mysql -h $READER -u admin -p"$PASS" -e "SELECT @@aurora_server_id;" 2>/dev/null
done
```

Resultado esperado (con 2 readers): las conexiones alternan entre instancias.

### Paso 3: Verificar estados de los Readers

```bash
aws rds describe-db-instances \
  --filters "Name=db-cluster-id,Values=db-lab-aurora-cluster" \
  --query 'DBInstances[*].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,AZ:AvailabilityZone,Tier:PromotionTier}' \
  --output table --region eu-west-1
```

**Si algún Reader está en estado `modifying` o `rebooting`**, el Reader endpoint solo puede usar los que están `available`.

### Paso 4: Ver conexiones activas por instancia (Enhanced Monitoring)

En CloudWatch → Metrics → RDS → Per-Instance:
- Métrica: `DatabaseConnections` por `DBInstanceIdentifier`
- Si solo una instancia tiene conexiones, el balanceo no está funcionando

---

## Causas y soluciones

### Causa 1 — La aplicación usa el Writer endpoint para lecturas (lo más común)

```python
# ❌ INCORRECTO: usar el writer para todo
DB_HOST = "db-lab-aurora-cluster.cluster-xxxx..."  # writer
conn = connect(host=DB_HOST)
cursor.execute("SELECT * FROM pedidos")  # va al writer

# ✅ CORRECTO: separar escritura y lectura
DB_WRITER = "db-lab-aurora-cluster.cluster-xxxx..."      # writer
DB_READER = "db-lab-aurora-cluster.cluster-ro-xxxx..."   # reader LB

write_conn = connect(host=DB_WRITER)  # para INSERT/UPDATE/DELETE
read_conn  = connect(host=DB_READER)  # para SELECT — balanceado
```

### Causa 2 — El Reader endpoint no balancea con conexiones persistentes

El Reader endpoint balancea la **apertura de nuevas conexiones** usando DNS round-robin. Si la aplicación abre una conexión y la mantiene indefinidamente, **no habrá balanceo** — la conexión siempre va al mismo Reader.

**Solución:** Usar un connection pool con límite de tiempo de vida:

```python
# Con SQLAlchemy: pool_recycle fuerza reconexión periódica
engine = create_engine(
    f"mysql+pymysql://admin:{password}@{reader_endpoint}/{db}",
    pool_recycle=300,    # reconectar cada 5 minutos → redistribuilding de conexiones
    pool_pre_ping=True,  # verificar conexión antes de usar
)
```

### Causa 3 — Solo hay un Reader Instance

Si solo hay un Reader, **toda la carga va a ese Reader** — no puede balancear porque no tiene a dónde distribuir.

**Fix:** Añadir un segundo Reader:

```bash
aws rds create-db-instance \
  --db-instance-identifier db-lab-aurora-reader-2 \
  --db-cluster-identifier db-lab-aurora-cluster \
  --engine aurora-mysql \
  --db-instance-class db.t3.medium \
  --availability-zone eu-west-1c \
  --region eu-west-1
```

### Causa 4 — Uno de los Readers está en estado no-healthy

Aurora excluye automáticamente los Readers en mal estado del endpoint. Verifica:

```bash
# Ver instancias con estado != available
aws rds describe-db-instances \
  --filters "Name=db-cluster-id,Values=db-lab-aurora-cluster" \
  --query 'DBInstances[?DBInstanceStatus!=`available`].{ID:DBInstanceIdentifier,Status:DBInstanceStatus}' \
  --output table --region eu-west-1
```

---

## Nota sobre el balanceo DNS de Aurora

El Reader endpoint usa **DNS con múltiples A records** que cambian dinámicamente:

```bash
# Resolver el reader endpoint varias veces
for i in {1..4}; do
  nslookup db-lab-aurora-cluster.cluster-ro-xxxx.eu-west-1.rds.amazonaws.com | grep Address
done
```

Puedes ver IPs distintas en cada resolución — eso es el balanceo DNS de Aurora.

**TTL del DNS:** 5 segundos → con `pool_recycle` corto, la carga se distribuye bien.

---

## Resumen SAA-C03

| Concepto | Detalle |
|----------|---------|
| ¿El Reader endpoint balancea escrituras? | **NO** — solo lecturas |
| ¿Cómo balancea el Reader endpoint? | DNS round-robin entre Readers disponibles |
| ¿Con conexiones persistentes hay balanceo? | **Solo al abrir nuevas conexiones** |
| ¿Puede el Writer también ser usado para lecturas? | Sí, pero no es la práctica recomendada |
| ¿Qué solución AWS absorbe la reconexión automática? | **RDS Proxy** |
