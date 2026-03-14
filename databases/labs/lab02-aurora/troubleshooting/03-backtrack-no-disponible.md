# Troubleshooting 03 — Backtrack no disponible o error al ejecutarlo

## Escenario

Intentas usar Backtrack para revertir la base de datos a un estado anterior, pero:

```
An error occurred (InvalidParameterCombination): Backtrack is not enabled for cluster db-lab-aurora-cluster
```

O al intentarlo desde la consola:
- El botón "Backtrack" aparece en gris / deshabilitado
- Recibes error "BacktrackWindowTooLarge" al especificar un timestamp muy antiguo

---

## Diagnóstico

### Paso 1: Verificar si Backtrack está habilitado

```bash
aws rds describe-db-clusters \
  --db-cluster-identifier db-lab-aurora-cluster \
  --query 'DBClusters[0].{BacktrackWindow:BacktrackWindow,EarliestBacktrack:EarliestBacktrackTime,LatestBacktrack:LatestRestorableTime}' \
  --output json --region eu-west-1
```

Resultado si Backtrack está deshabilitado:
```json
{
  "BacktrackWindow": 0,
  "EarliestBacktrack": null,
  "LatestBacktrack": "2024-01-15T12:30:00Z"
}
```

Resultado si está habilitado:
```json
{
  "BacktrackWindow": 3600,
  "EarliestBacktrack": "2024-01-15T11:30:00Z",
  "LatestBacktrack": "2024-01-15T12:30:00Z"
}
```

### Paso 2: Verificar que es Aurora MySQL (no PostgreSQL)

```bash
aws rds describe-db-clusters \
  --db-cluster-identifier db-lab-aurora-cluster \
  --query 'DBClusters[0].Engine' \
  --output text --region eu-west-1
# aurora-mysql ← OK
# aurora-postgresql ← Backtrack NO disponible
```

### Paso 3: Verificar el timestamp solicitado

El timestamp debe estar dentro de la ventana de Backtrack y ser posterior al `EarliestBacktrackTime`.

```bash
# Ver la ventana disponible
aws rds describe-db-clusters \
  --db-cluster-identifier db-lab-aurora-cluster \
  --query 'DBClusters[0].{Window:BacktrackWindow,Earliest:EarliestBacktrackTime}' \
  --output table --region eu-west-1
```

---

## Causas y soluciones

### Causa 1 — Backtrack no estaba habilitado al crear el cluster

**Esta es la limitación más importante:** Backtrack **solo se puede habilitar al crear el cluster**. No se puede activar en un cluster existente.

```
❌ NO se puede hacer:
aws rds modify-db-cluster --db-cluster-identifier db-lab-aurora-cluster \
  --backtrack-window 3600  # Esto falla si no estaba habilitado al crear

✅ Lo que se puede hacer:
- Habilitar al crear el cluster (--backtrack-window 3600)
- Restaurar el cluster desde un snapshot con Backtrack habilitado
```

**Fix (si el cluster no tiene Backtrack):**

Opción A — Crear un nuevo cluster con Backtrack desde un snapshot:

```bash
# 1. Crear snapshot manual del cluster actual
aws rds create-db-cluster-snapshot \
  --db-cluster-identifier db-lab-aurora-cluster \
  --db-cluster-snapshot-identifier db-lab-aurora-with-backtrack-snap \
  --region eu-west-1

aws rds wait db-cluster-snapshot-available \
  --db-cluster-snapshot-identifier db-lab-aurora-with-backtrack-snap \
  --region eu-west-1

# 2. Restaurar con Backtrack habilitado
aws rds restore-db-cluster-from-snapshot \
  --db-cluster-identifier db-lab-aurora-cluster-v2 \
  --snapshot-identifier db-lab-aurora-with-backtrack-snap \
  --engine aurora-mysql \
  --backtrack-window 3600 \
  --db-subnet-group-name aurora-lab-subnetgroup \
  --vpc-security-group-ids $SG_AURORA \
  --region eu-west-1
```

Opción B — Recrear el cluster con Backtrack desde el principio (lab):

```bash
# Usar cli/01-aurora-cluster.sh que ya incluye --backtrack-window 3600
```

### Causa 2 — Timestamp fuera de la ventana de Backtrack

Si el timestamp que proporcionas es anterior al `EarliestBacktrackTime`, recibirás:

```
InvalidParameterValue: The specified backtrack time '2024-01-14T10:00:00Z'
is not in range [2024-01-15T11:30:00Z, 2024-01-15T12:30:00Z]
```

**Fix:** Usa el timestamp más antiguo disponible si necesitas retroceder tanto:

```bash
EARLIEST=$(aws rds describe-db-clusters \
  --db-cluster-identifier db-lab-aurora-cluster \
  --query 'DBClusters[0].EarliestBacktrackTime' \
  --output text --region eu-west-1)

# Usar ese timestamp como target si es suficientemente antiguo
aws rds backtrack-db-cluster \
  --db-cluster-identifier db-lab-aurora-cluster \
  --backtrack-to "$EARLIEST" \
  --region eu-west-1
```

Si no es suficiente: usar **PITR (Point-in-Time Recovery)** que cubre todo el período de retención (1-35 días).

### Causa 3 — Motor Aurora PostgreSQL

Backtrack no existe para Aurora PostgreSQL. Solo está disponible para Aurora MySQL.

**Alternativa para Aurora PostgreSQL:** PITR (Point-in-Time Recovery):

```bash
aws rds restore-db-cluster-to-point-in-time \
  --db-cluster-identifier db-lab-aurora-restored \
  --source-db-cluster-identifier db-lab-aurora-cluster \
  --restore-to-time "2024-01-15T10:00:00Z" \
  --region eu-west-1
```

---

## Diferencia Backtrack vs PITR

| | Backtrack | PITR |
|--|--|--|
| Motor | Aurora MySQL only | Todos (RDS + Aurora) |
| Velocidad | Segundos (in-place) | Minutos (nuevo cluster) |
| Resultado | Mismo cluster, rebobinado | Nuevo cluster |
| Ventana máxima | 72 horas (configurable) | Hasta 35 días |
| ¿Interrumpe el servicio? | Sí (~breve downtime) | No (nuevo cluster) |
| Configuración | Al crear el cluster | Siempre disponible |

---

## Clave SAA-C03

> **Backtrack = Aurora MySQL only + habilitar al crear**
>
> Si el examen dice "necesita revertir cambios accidentales sin restaurar un backup completo" → **Aurora Backtrack**.
>
> Si dice "necesitar restaurar a un punto específico" sin mencionar Aurora MySQL o sin la restricción de velocidad → puede ser **PITR**.
