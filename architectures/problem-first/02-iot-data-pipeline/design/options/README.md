# Opciones de diseño consideradas

## Opción A: Arquitectura propuesta (elegida)

```
IoT Core → Kinesis Streams → Lambda → Firehose → S3 → Athena
                                    ↘ DynamoDB
IoT Core Rule (SQL) → Lambda → SNS (alertas)
```

**✓ Pros:**
- Dos rutas independientes: alertas <10s sin afectar al pipeline de datos
- Kinesis permite múltiples consumers sin duplicar mensajes
- Parquet + Snappy: 20× reducción de coste en Athena vs JSON crudo
- Serverless end-to-end: coste proporcional al volumen, $0 cuando idle
- Replay histórico: Kinesis retiene 7 días para re-procesar si falla Lambda

**✗ Contras:**
- Latencia de Kinesis: batch mínimo de 1 segundo antes de que Lambda procese
- Parquet conversion: añade complejidad en Lambda (necesita biblioteca pyarrow)
- Glue Crawler: puede tardar horas en descubrir particiones nuevas

---

## Opción B: IoT Core → MSK (Managed Kafka) → Flink + S3

```
IoT Core → MSK (Kafka) → Kinesis Analytics (Flink) → S3
                                                    → DynamoDB
                                                    → alertas en tiempo real
```

**✓ Pros:**
- Kafka es el estándar de la industria para streaming (interoperabilidad)
- Flink: ventanas complejas, joins entre streams, ML en streaming
- Multi-region replication nativa con Kafka MirrorMaker
- Ecosistema rico: Kafka Connect para muchos destinos

**✗ Contras:**
- **Coste:** MSK mínimo 3 brokers × `kafka.m5.large` × $0.096/hora = $207/mes
- Kinesis Analytics (Flink): mínimo 1 KPU = $0.11/hora × 730h = $80/mes
- Total mínimo solo infraestructura: ~$287/mes (ya supera el budget de $500)
- Complejidad operacional alta: gestionar Kafka, topics, consumer groups
- Overkill para 10K sensores

**Cuándo elegir B:** volúmenes de 100K+ dispositivos, necesidad de Kafka Connect para múltiples destinos, equipo con experiencia en Kafka, requirement de on-prem hybrid.

---

## Opción C: IoT Core → SQS + SNS fan-out → Lambda

```
IoT Core → SNS Topic → [SQS procesador] → Lambda (DynamoDB + S3)
                     → [SQS alertas]    → Lambda (SNS notificaciones)
```

**✓ Pros:**
- Sin coste de Kinesis (SQS es más barato a bajo volumen)
- Simplicidad: no hay shards que gestionar
- Fan-out via SNS para múltiples consumers

**✗ Contras:**
- **Sin ordenamiento:** SQS Standard no garantiza orden (FIFO tiene límite 3K TPS, insuficiente)
- **Sin replay:** mensaje borrado tras lectura exitosa
- SNS → SQS: duplicación de mensajes (mismo mensaje en 2 colas)
- A 1.000 msg/s: SNS + SQS cost = ~$16/mes vs Kinesis ~$15/mes (similar, pero sin replay)
- DLQ obligatorio o se pierden mensajes fallidos permanentemente

**Cuándo elegir C:** <100 dispositivos, no se necesita replay, el equipo no conoce Kinesis.

---

## Opción D: IoT Core → Timestream (base de datos time-series)

```
IoT Core Rule → Timestream (ingesta directa)
Timestream → Grafana (dashboards)
Timestream → Lambda (alertas via scheduled query)
```

**✓ Pros:**
- Base de datos nativa para series temporales
- Grafana integración nativa
- Lifecycle automático: memoria (reciente) → SSD (días) → S3 (histórico)
- No necesita Kinesis ni Firehose

**✗ Contras:**
- **Coste:** $0.036/GB escrito + $0.01/GB memoria + $0.036/GB SSD almacenado
  Con 10K sensores × 100 bytes × 6 msg/min = 360 MB/hora = 8.6 GB/día
  Coste escritura: 8.6 GB × $0.036 = $0.31/día = $9.30/mes
  Almacenamiento 2 años: 6.2 TB × $0.036 = $222/mes — supera el presupuesto
- No hay Athena ni herramientas SQL estándar (solo SQL propio de Timestream)
- Vendor lock-in en el query language

**Cuándo elegir D:** dashboards Grafana como prioridad, volumen <1K dispositivos, sin necesidad de SQL estándar para análisis.

---

## Tabla comparativa

| Criterio | A (elegida) | B (MSK+Flink) | C (SQS+SNS) | D (Timestream) |
|----------|-------------|---------------|-------------|----------------|
| Latencia alertas | <10s | <5s | ~5s | ~30s |
| Ordering | ✓ (por device) | ✓ | ✗ (Standard) | N/A |
| Replay histórico | ✓ 7 días | ✓ configurable | ✗ | ✗ |
| Coste ~10K sensores | ~$150-200 | ~$287+ | ~$80 | ~$240+ |
| Queries históricas | Athena (SQL) | Flink SQL | Custom Lambda | SQL propio |
| Complejidad | Media | Alta | Baja | Baja |
| Time to market | Medio | Alto | Bajo | Bajo |

**Decisión:** Opción A cumple los tres requisitos (alertas <10s, histórico 2 años, <$500/mes) con complejidad media. Opción C si el presupuesto es el único criterio. Opción B solo si escalan a 100K+ dispositivos o necesitan Kafka.
