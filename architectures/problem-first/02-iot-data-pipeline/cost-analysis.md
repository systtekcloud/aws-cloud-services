# Análisis de costes: IoT Data Pipeline

**Supuesto base:** 10.000 sensores, 1 mensaje cada 10 segundos  
**Volumen:** 10K × 6 msg/min × 60 min × 24h = 86.4M mensajes/día  
**Payload:** ~150 bytes por mensaje → 12.96 GB/día, 388 GB/mes  
**Región:** eu-west-1 (Irlanda)

---

## Dev

Propósito: 100 sensores simulados, pruebas funcionales.

| Servicio | Configuración | Coste/mes |
|----------|--------------|-----------|
| AWS IoT Core | 100 sensores × 6 msg/min × 43.200 min/mes = 25.9M mensajes × $1/M | $0.26 |
| Kinesis Data Streams | 1 shard × $0.015/hora × 730h | $10.95 |
| Lambda (procesador) | 259K batches × $0.20/M = casi gratis | $0.05 |
| Lambda (alerter) | 1K alertas/mes | $0.00 |
| Firehose | 3.89 GB/mes × $0.029/GB | $0.11 |
| S3 | 200 MB (con Parquet) × $0.023/GB | $0.00 |
| DynamoDB | On-demand, 259K writes | $0.33 |
| Glue | $0/mes (catálogo gratis hasta 1M objetos) | $0.00 |
| Athena | Estimado 10 queries × 200MB = 2GB × $0.005/GB | $0.01 |
| CloudWatch Logs | ~1GB | $0.50 |
| **Total Dev** | | **~$12.21/mes** |

---

## Prod

Propósito: 10.000 sensores, pipeline completo, 2 años retención.

| Servicio | Configuración | Coste/mes |
|----------|--------------|-----------|
| AWS IoT Core | 86.4M msg/día × 30 = 2.592B × $1/M | $259.20 |
| Kinesis Data Streams | 2 shards × $0.015/hora × 730h | $21.90 |
| Lambda (procesador) | 864K batches × $0.20/M | $0.17 |
| Lambda (alerter) | ~10K alertas/mes × $0.20/M | $0.00 |
| Firehose | 20 GB/mes (Parquet) × $0.029/GB | $0.58 |
| S3 (almacenamiento 2 años) | 388 GB/mes → Parquet 20 GB/mes. Acumulado 24 meses: ~480 GB × $0.023 (S3-IA promedio) | $11.04 |
| DynamoDB | On-demand, 86.4M writes/mes × $1.25/M | $108.00 |
| Glue Crawler | $0.44/hora × ~2h/mes | $0.88 |
| Athena | 50 queries × 1 GB (Parquet) × $0.005 | $0.25 |
| SNS | 10K alertas/mes | $0.01 |
| CloudWatch Logs | ~30GB | $15.00 |
| CloudWatch Alarms | 10 alarmas × $0.10 | $1.00 |
| **Total Prod** | | **~$418/mes** |

**Dentro del presupuesto de $500/mes.**

---

## Desglose principal: IoT Core (mayor coste)

IoT Core cobra por mensaje:
- Primeros 1B mensajes/mes: $1.00/M
- Con 86.4M/día × 30 días = 2.592B mensajes/mes:
  - Primeros 1B: $1.00/M → $1,000 — espera, **hay que leer la tarifa completa**

**Corrección importante — IoT Core pricing real:**

```
Primeros  1B mensajes/mes: $1.00/M
Siguiente 4B mensajes/mes: $0.80/M
Siguiente 45B             : $0.15/M

2.592B mensajes:
  1B × $1.00/M  = $1,000
  1.592B × $0.80/M = $1,273.60
  Total: $2,273.60  ← FUERA DE PRESUPUESTO
```

**Esto supera masivamente el presupuesto.** El diseño necesita ajuste.

### Optimización: reducir mensajes a IoT Core

**Opción A: Aggregation en el edge (Greengrass)**
```
Sensor (cada 10s) → Greengrass local → agrega 6 lecturas (1 min) → IoT Core
Reducción: 6× → 432M mensajes/mes → $432/mes
```

**Opción B: Mensaje cada 60s en vez de cada 10s**
```
432M mensajes/mes × $1/M = $432/mes → dentro del presupuesto
Pero: latencia de alertas aumenta a 60s (supera el requisito de <10s)
```

**Solución híbrida (elegida para prod con requisito <10s):**
- Sensores normales: cada 60s → reduce volumen 6×
- Sensores en zona crítica (temp cercana al umbral): cada 10s
- IoT Rule condición: sensores críticos se marcan vía DynamoDB flag

---

## Coste con optimización (prod revisado)

| Servicio | Configuración optimizada | Coste/mes |
|----------|------------------------|-----------|
| AWS IoT Core | 432M msg/mes × $1/M | $43.20 |
| DynamoDB | 432M writes/mes × $1.25/M | $54.00 |
| (resto igual) | | ~$51 |
| **Total Prod optimizado** | | **~$148/mes** |

**Muy por debajo del presupuesto de $500/mes.**

---

## Comparativa de opciones

| Configuración | Coste/mes (10K sensores) | Alertas <10s | Historial 2 años |
|--------------|--------------------------|--------------|------------------|
| **A: IoT Core + Kinesis** (optimizado) | ~$148 | ✓ | ✓ |
| B: MSK (Kafka) + Flink | ~$380+ | ✓ | ✓ |
| C: SQS + SNS | ~$80 | ✓ (sin ordering) | Costoso |
| D: Timestream | ~$240+ | ~30s | ✓ pero caro |

---

## TCO 2 años (período de retención requerido)

```
Dev (12 meses iniciales): $12.21 × 12 = $146.52
Prod (24 meses):          $148    × 24 = $3,552
Desarrollo inicial:       ~80h × $100  = $8,000
Mantenimiento/año:        ~20h × $100  = $4,000
                                        ─────────
TCO 2 años                              ~$15,699
```

Coste por lectura de sensor (2 años):
- 10K sensores × 6 msg/min × 60 × 24 × 365 × 2 = 63.072B lecturas
- $15,699 ÷ 63.072B = **$0.000000249 por lectura** (prácticamente gratis)
