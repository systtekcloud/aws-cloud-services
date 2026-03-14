# Troubleshooting 04 — Multi-AZ mal entendido: "el standby debería escalar lecturas"

## Escenario

Habilitas Multi-AZ en tu instancia RDS esperando que el standby ayude con las lecturas. Tu aplicación sigue enviando todas las queries (lecturas y escrituras) al mismo endpoint y el rendimiento no mejora. En algunos casos, incluso crees que hay dos endpoints disponibles.

---

## El malentendido

Este es el error conceptual **más evaluado en el SAA-C03** relacionado con RDS:

```
INCORRECTO: "Multi-AZ mejora el rendimiento porque usa dos instancias"
CORRECTO:   "Multi-AZ es SOLO para High Availability (HA)"
            El standby NUNCA acepta tráfico (ni lectura ni escritura)
```

---

## Diagnóstico: confirmar la configuración

```bash
# Ver el estado de Multi-AZ
aws rds describe-db-instances \
  --db-instance-identifier db-lab-rds-instance \
  --query 'DBInstances[0].{MultiAZ:MultiAZ,SecondaryAZ:SecondaryAvailabilityZone,Endpoint:Endpoint.Address}' \
  --output table --region eu-west-1
```

Resultado:
```
-------------------------------------------------------
| MultiAZ: True | SecondaryAZ: eu-west-1b | Endpoint: db-lab-rds-instance.xxxx |
-------------------------------------------------------
```

**Observa:** Solo hay UN endpoint. No hay "endpoint del standby" porque el standby no acepta conexiones.

---

## La diferencia que debes memorizar

```
┌────────────────────────────────────────────────────────────────────────────┐
│  MULTI-AZ                                                                   │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                              │
│  Primary (eu-west-1a)  ──── sync replication ────►  Standby (eu-west-1b)  │
│       R + W                                            INVISIBLE             │
│  (tu app conecta aquí)                             (AWS lo gestiona solo)   │
│                                                                              │
│  Propósito: FAILOVER AUTOMÁTICO si el primary falla                        │
│  El DNS apunta automáticamente al standby (~1-2 min)                       │
│  CERO lectura desde el standby en condiciones normales                     │
└────────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────────────┐
│  READ REPLICA                                                               │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                              │
│  Primary (eu-west-1a)  ──── async replication ────►  Replica (eu-west-1b) │
│       R + W                                               R only             │
│  (endpoint 1)                                         (endpoint 2 distinto)│
│                                                                              │
│  Propósito: ESCALAR LECTURAS (reporting, analytics, reducir carga)         │
│  Tu app debe usar explícitamente el endpoint de la réplica para lecturas   │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## Solución: Crear Read Replica para escalar lecturas

Si necesitas escalar lecturas, la respuesta es Read Replica, no Multi-AZ:

```bash
aws rds create-db-instance-read-replica \
  --db-instance-identifier db-lab-rds-replica \
  --source-db-instance-identifier db-lab-rds-instance \
  --db-instance-class db.t3.micro \
  --availability-zone eu-west-1b \
  --no-publicly-accessible \
  --region eu-west-1

# Esperar
aws rds wait db-instance-available \
  --db-instance-identifier db-lab-rds-replica \
  --region eu-west-1

# Obtener el endpoint de la réplica (DISTINTO al primary)
aws rds describe-db-instances \
  --db-instance-identifier db-lab-rds-replica \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text --region eu-west-1
```

Ahora tu app puede usar **dos endpoints distintos**:
```
Escrituras (INSERT/UPDATE/DELETE) → db-lab-rds-instance.xxxx  (primary)
Lecturas (SELECT reporting)       → db-lab-rds-replica.xxxx   (replica)
```

---

## Tabla comparativa para el examen

| Pregunta del examen | Respuesta correcta |
|---------------------|--------------------|
| "Necesito recuperación automática si falla la instancia" | **Multi-AZ** |
| "Necesito reducir la carga de lecturas del primary" | **Read Replica** |
| "Necesito escalar las operaciones de SELECT" | **Read Replica** |
| "Necesito RPO/RTO bajo ante fallo de AZ" | **Multi-AZ** |
| "El standby debe procesar reportes" | ❌ IMPOSIBLE con Multi-AZ — usar Read Replica |
| "Necesito HA Y escalar lecturas" | **Multi-AZ + Read Replica** (coexisten) |
| "Necesito >5 read replicas" | **Aurora** (soporta hasta 15) |

---

## Resumen

```
Si la pregunta dice:       → Servicio correcto:
"alta disponibilidad"      → Multi-AZ
"failover automático"      → Multi-AZ
"escalar lecturas"         → Read Replica
"reporting sin impactar"   → Read Replica
"AMBAS cosas"              → Multi-AZ + Read Replica
```
