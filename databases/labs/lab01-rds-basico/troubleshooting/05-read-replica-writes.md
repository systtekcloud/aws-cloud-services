# Troubleshooting 05 — "Error: read-only al hacer INSERT en la Read Replica"

## Escenario

Tienes la Read Replica configurada y conectas al endpoint de la réplica. Intentas insertar datos:

```sql
INSERT INTO pedidos (usuario_id, total) VALUES (1, 59.99);
```

Y obtienes:

```
ERROR 1290 (HY000): The MySQL server is running with the --read-only option
so it cannot execute this statement
```

---

## Diagnóstico

```bash
# Confirmar que el endpoint es la réplica (no el primary)
mysql -h db-lab-rds-replica.xxxx.eu-west-1.rds.amazonaws.com -u admin -p -e "SELECT @@hostname, @@read_only;"
```

Resultado:
```
+-----------------------------------+-----------+
| @@hostname                        | @@read_only |
+-----------------------------------+-----------+
| db-lab-rds-replica-xxxxxxxx       |           1 |  ← 1 = TRUE = solo lectura
+-----------------------------------+-----------+
```

---

## Causa

Las Read Replicas son **read-only por diseño**. No es un error de configuración — es el comportamiento correcto y esperado.

```
Primary ──── async replication ────► Read Replica
  R + W                                R only
```

La flag `--read-only` se establece automáticamente en todas las Read Replicas de RDS. No se puede cambiar mientras el rol sea "Replica".

---

## Solución: Separar endpoints por operación

La arquitectura correcta es usar dos endpoints distintos en tu aplicación:

```python
# Ejemplo Python (psycopg2 o MySQL connector)

import os

# Configuración de conexiones
DB_PRIMARY_HOST  = "db-lab-rds-instance.xxxx.eu-west-1.rds.amazonaws.com"
DB_REPLICA_HOST  = "db-lab-rds-replica.xxxx.eu-west-1.rds.amazonaws.com"
DB_PORT = 3306

# Conexión de escritura (INSERT, UPDATE, DELETE, DDL)
conn_write = connect(host=DB_PRIMARY_HOST, port=DB_PORT, ...)

# Conexión de lectura (SELECT)
conn_read = connect(host=DB_REPLICA_HOST, port=DB_PORT, ...)

# NUNCA hacer esto:
conn_read.cursor().execute("INSERT INTO ...")  # ← Fallará siempre
```

```bash
# Verificar que puedes LEER de la réplica
mysql -h db-lab-rds-replica.xxxx.eu-west-1.rds.amazonaws.com -u admin -p -e "SELECT COUNT(*) FROM labdb.test_tabla;"

# Verificar que escribes al PRIMARY
mysql -h db-lab-rds-instance.xxxx.eu-west-1.rds.amazonaws.com -u admin -p -e "INSERT INTO labdb.test_tabla VALUES (99, 'desde primary');"
```

---

## Si necesitas convertir la réplica en un DB independiente (promoción)

Si necesitas una instancia de lectura/escritura separada (para failover manual o crear un entorno de desarrollo):

```bash
# Promover la réplica a instancia standalone
aws rds promote-read-replica \
  --db-instance-identifier db-lab-rds-replica \
  --region eu-west-1

# Esperar a que esté available
aws rds wait db-instance-available \
  --db-instance-identifier db-lab-rds-replica \
  --region eu-west-1
```

Después de la promoción:
- La instancia ya NO es réplica (sin lag, sin relación con el primary)
- Se convierte en instancia standalone que acepta escrituras
- Ya NO recibe cambios del primary (la replicación se rompe)

> ⚠️ **Atención:** Esto rompe la replicación permanentemente. Úsalo solo si realmente necesitas una instancia independiente.

---

## Resumen para el examen

| Pregunta | Respuesta |
|----------|-----------|
| ¿Puede una Read Replica aceptar escrituras? | **NO** — `--read-only` siempre activo |
| ¿Cómo hago que una réplica acepte escrituras? | **Promover** (rompe la replicación) |
| ¿El standby Multi-AZ acepta lecturas? | **NO** — invisible, solo para failover |
| ¿Qué endpoint uso para SELECT reporting? | **Endpoint de la Read Replica** |
| ¿Qué endpoint uso para INSERT/UPDATE? | **Endpoint del Primary** |
