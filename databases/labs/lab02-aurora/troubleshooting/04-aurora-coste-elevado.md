# Troubleshooting 04 — Coste de Aurora inesperadamente alto

## Escenario

Revisas tu factura de AWS y el coste de Aurora es mucho mayor de lo esperado:
- Dos instancias `db.t3.medium` funcionando sin parar
- Coste de storage escalando inesperadamente
- Cargos de I/O que no esperabas

---

## Diagnóstico de costes

### Paso 1: Revisar qué instancias están activas

```bash
# Ver TODAS las instancias Aurora en la región
aws rds describe-db-instances \
  --filters "Name=engine,Values=aurora-mysql,aurora-postgresql" \
  --query 'DBInstances[*].{ID:DBInstanceIdentifier,Class:DBInstanceClass,Status:DBInstanceStatus,MultiAZ:MultiAZ}' \
  --output table --region eu-west-1
```

### Paso 2: Desglose de costes Aurora

Aurora tiene **tres componentes de coste separados**:

```
┌─────────────────────────────────────────────────────────────────────┐
│  COMPONENTES DE COSTE DE AURORA                                      │
│                                                                      │
│  1. Instancias (compute)                                             │
│     db.t3.medium: ~0.073 USD/h = ~52 USD/mes por instancia          │
│     db.r6g.large: ~0.29 USD/h = ~209 USD/mes                        │
│                                                                      │
│  2. Storage Aurora                                                   │
│     ~0.10 USD/GB·mes (crece automáticamente en 10 GB chunks)        │
│     NO se cobra por el storage provisionado — solo por lo usado      │
│                                                                      │
│  3. I/O Requests (Aurora Standard)                                   │
│     ~0.20 USD por 1 millón de operaciones I/O                       │
│     En Aurora I/O-Optimized: sin cargo de I/O, pero +25% storage   │
└─────────────────────────────────────────────────────────────────────┘
```

### Paso 3: Ver el storage actual del cluster

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name FreeStorageSpace \
  --dimensions Name=DBClusterIdentifier,Value=db-lab-aurora-cluster \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 3600 \
  --statistics Average \
  --region eu-west-1
```

---

## Causas y soluciones

### Causa 1 — Tener Reader Instance cuando no se necesita

Cada instancia (Writer + Reader) tiene coste independiente. En labs/dev, a menudo no se necesita Reader.

**Fix:** Eliminar el Reader si no lo usas:

```bash
aws rds delete-db-instance \
  --db-instance-identifier db-lab-aurora-reader \
  --skip-final-snapshot \
  --region eu-west-1
```

**Ahorro:** ~0.073 USD/h × 24h × 30d = ~52 USD/mes

### Causa 2 — Cluster activo fuera del horario de lab

La principal fuente de coste en labs es **olvidar el cleanup**. Dos instancias db.t3.medium cuestan ~0.15 USD/hora = ~108 USD/mes.

**Fix inmediato:**

```bash
# Cleanup completo
bash cli/99-cleanup.sh
```

**Prevención:** Configura una alarma de coste:

```bash
aws budgets create-budget \
  --account-id $(aws sts get-caller-identity --query Account --output text) \
  --budget '{
    "BudgetName": "db-labs-daily-limit",
    "BudgetLimit": {"Amount": "3", "Unit": "USD"},
    "TimeUnit": "DAILY",
    "BudgetType": "COST"
  }' \
  --notifications-with-subscribers '[{
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 80
    },
    "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "tu@email.com"}]
  }]'
```

### Causa 3 — Usar Aurora cuando RDS MySQL sería suficiente

Aurora cuesta más por instancia (~1.2x) que RDS MySQL equivalente.

**Cuándo Aurora sí tiene sentido (a pesar del mayor coste):**
- Necesitas >5 Read Replicas
- Necesitas failover <30 seg
- Necesitas Backtrack
- Workload con mucha I/O (Aurora I/O-Optimized puede ser más barato)
- Necesitas Aurora Serverless v2

**Cuándo usar RDS MySQL (más barato):**
- 1 instancia, Single-AZ → usa `db.t3.micro` RDS (~0.017 USD/h)
- Máximo 5 Read Replicas es suficiente
- Failover de 1-2 min es aceptable

### Causa 4 — Aurora Standard con mucha I/O (considerar I/O-Optimized)

Si tus aplicaciones hacen muchas lecturas/escrituras:

```bash
# Ver I/O metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name VolumeReadIOPs \
  --dimensions Name=DBClusterIdentifier,Value=db-lab-aurora-cluster \
  --start-time $(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 3600 \
  --statistics Sum \
  --region eu-west-1
```

**Regla de oro:**
- Si I/O cuesta >25% del total del cluster → considera Aurora I/O-Optimized
- I/O-Optimized elimina el cargo de I/O pero añade +25% al storage

### Causa 5 — Backtrack window grande aumenta el storage

Backtrack requiere almacenar el change log para toda la ventana configurada. Una ventana de 72h en un cluster con mucha escritura puede añadir GBs de storage.

**Fix:** Reducir la ventana de Backtrack en clusters que no la necesiten:

```bash
# Reducir a 1h si solo se usa para demos
aws rds modify-db-cluster \
  --db-cluster-identifier db-lab-aurora-cluster \
  --backtrack-window 3600 \
  --apply-immediately \
  --region eu-west-1
```

---

## Tabla de costes Aurora (eu-west-1, aproximado 2024)

| Recurso | Coste |
|---------|-------|
| db.t3.medium | ~0.073 USD/h |
| db.r6g.large | ~0.29 USD/h |
| Storage Aurora | ~0.10 USD/GB·mes |
| I/O Requests (Standard) | ~0.20 USD/millón |
| Backup storage | Gratis hasta 1× cluster storage |
| Data transfer (mismo AZ) | Gratis |

**Lab típico (Writer + Reader db.t3.medium, 8h):** ~1.20 USD

---

## Prevención en labs

1. **Siempre ejecutar `99-cleanup.sh`** al terminar el lab
2. **Configurar alarma de presupuesto** < 3 USD/día
3. **Usar `enable_reader = false`** en terraform por defecto para ahorrar
4. **Programar stop automático** (no disponible en Aurora, solo en RDS)
   - Alternativa Aurora: usar **Serverless v2** que escala a 0 ACU (mínimo 0.5 ACU pero muy económico)
