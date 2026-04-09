# Amazon MSK — Mapa Conceptual

> **Módulo:** `data/labs/lab03-msk` | **Región:** eu-west-1

---

## Qué es MSK

**Amazon MSK (Managed Streaming for Apache Kafka)** es Kafka gestionado por AWS. AWS se encarga de crear y mantener los brokers Kafka, las zonas de disponibilidad, los upgrades, y el monitoreo. Tú sigues teniendo acceso completo a la API de Kafka — producers, consumers, topics, partitions, consumer groups — exactamente igual que en Kafka on-prem.

```
On-prem Kafka:
  Tu equipo gestiona: ZooKeeper/KRaft, brokers, almacenamiento, upgrades, alertas, AZ failover

MSK:
  AWS gestiona:      brokers, ZooKeeper/KRaft, almacenamiento, AZ failover, upgrades menores
  Tú gestionas:      topics, partitions, consumer groups, configuración de Kafka
```

**Analogía DevOps:** MSK ≈ **RDS pero para Kafka**. Como RDS te da MySQL/PostgreSQL sin gestionar el motor, MSK te da Kafka sin gestionar los brokers.

---

## MSK vs Kinesis Data Streams — Decisión crítica para el examen

| | MSK | Kinesis Data Streams |
|---|---|---|
| **Cuándo usar** | Ya tienes ecosistema Kafka existente | Empiezas desde cero en AWS |
| **API** | API nativa Kafka (producers, consumers) | API propietaria AWS |
| **Ecosistema** | Kafka Connect, Kafka Streams, Flink, Spark | Lambda, KCL, KDA, Firehose |
| **Experiencia de equipo** | Equipos con conocimiento de Kafka | Sin requisito previo de Kafka |
| **Control** | Alto — configuración broker, retention, compaction | Medio — shards, retención |
| **Integración AWS nativa** | Limitada (Lambda trigger, IAM MSK) | Amplia (Lambda, Firehose, KDA nativo) |
| **Particiones** | Configurable por topic (sin límite práctico) | Shards: 1.000 records/seg por shard |
| **Replay** | Según retention configurada en el topic | 1–365 días |
| **Migración lift-and-shift** | Sí — misma API, cambia el endpoint | No — reescritura de producers/consumers |
| **Coste mínimo** | MSK Serverless: pay-per-use | $0.015/hora por shard |

**Regla del examen:**
- ¿Migración de Kafka on-prem a AWS? → **MSK** (sin cambiar el código)
- ¿Necesitas Kafka Connect, Kafka Streams, o Mirror Maker? → **MSK**
- ¿Empiezas desde cero, no hay Kafka previo, equipo sin experiencia Kafka? → **Kinesis**
- ¿Integración nativa con Lambda/Firehose/KDA? → **Kinesis**

---

## MSK Serverless vs MSK Provisioned

| | MSK Serverless | MSK Provisioned |
|---|---|---|
| **Gestión de capacidad** | Automática — escala sola | Manual — defines número de brokers |
| **Coste** | Pago por uso (partition-hours + GB) | Pago por broker (instancia siempre encendida) |
| **Control** | Bajo — no configuras broker individually | Alto — tipo de instancia, almacenamiento, IOPS |
| **Cuándo usar** | Cargas variables o impredecibles, equipos sin expertise Kafka | Cargas predecibles, alto throughput sostenido, tuning fino |
| **Limitaciones** | Sin soporte para algunas configuraciones avanzadas | Requires gestión de capacidad |
| **Multi-AZ** | Siempre (automático) | Configurable (multi-AZ recomendado) |

Para aprendizaje y labs: **MSK Serverless** — sin coste fijo, sin gestión de brokers.

---

## MSK Connect

Servicio managed para ejecutar **Kafka Connect** sin gestionar workers. Conectores pre-built para mover datos entre Kafka y otros sistemas.

```
MSK (topics)
     │
     ▼
MSK Connect (Connector workers — gestionados por AWS)
     │
     ├──► S3 Sink Connector      → escribe en S3 (archivado)
     ├──► DynamoDB Sink Connector → escribe en DynamoDB
     ├──► OpenSearch Sink         → indexa en OpenSearch
     └──► JDBC Source Connector   → lee de RDS y publica en Kafka
```

**MSK Connect vs Lambda consumer:**

| | MSK Connect | Lambda trigger MSK |
|---|---|---|
| **Ideal para** | Mover datos a S3/DynamoDB/OpenSearch | Lógica de negocio por mensaje |
| **Throughput** | Alto — workers dedicados, batch nativo | Limitado por concurrencia Lambda |
| **Configuración** | Declarativa (connector config) | Código (handler function) |
| **Transformaciones** | SMT (Single Message Transforms) simples | Lógica arbitraria |
| **Coste** | Por MCU-hora (worker capacity) | Por invocación |

---

## Arquitectura típica de MSK

```
Producers (app, microservicios, on-prem)
          │
          ▼
    MSK Cluster
    ┌────────────────────────────────┐
    │  Topic: orders  (6 partitions) │
    │  Topic: metrics (3 partitions) │
    │  Topic: events  (12 partitions)│
    └────────────────────────────────┘
          │
          ├──► Consumer Group A (procesamiento pedidos)
          ├──► Consumer Group B (analytics)
          ├──► MSK Connect → S3 (archivado)
          └──► Lambda (alertas tiempo real)
```

Cada consumer group tiene su propio offset — leen el mismo topic de forma independiente, igual que KDS con múltiples consumers.

---

## Conceptos Kafka que aplican en MSK

| Concepto | MSK | Equivalente KDS |
|---|---|---|
| **Topic** | Categoría lógica de mensajes | Stream |
| **Partition** | División del topic para paralelismo | Shard |
| **Partition Key** | Clave que determina la partición | Partition Key |
| **Consumer Group** | Grupo de consumers que comparten la carga | - (en KDS cada consumer lee todo) |
| **Offset** | Posición del consumer en la partición | Sequence Number / ShardIterator |
| **Retention** | Tiempo que se guardan los mensajes | Retención del stream |
| **Broker** | Servidor Kafka que almacena particiones | - (abstracción en KDS) |
