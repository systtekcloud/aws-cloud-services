# Kinesis — Mapa Conceptual

> **Módulo:** `data/labs/lab01-kinesis` | **Región:** eu-west-1

---

## KDS vs Firehose — La diferencia crítica

| | Kinesis Data Streams (KDS) | Kinesis Data Firehose |
|---|---|---|
| **Tipo** | Streaming en tiempo real | Managed delivery hacia destinos |
| **Consumers** | Múltiples consumers independientes (tú los gestionas) | Sin gestión de consumers (AWS lo hace) |
| **Latencia** | Milisegundos | Near real-time (~60 seg mínimo buffer) |
| **Retención** | 1–365 días (configurable) | No aplica — delivery directo |
| **Destinos** | Cualquier consumer (Lambda, EC2, KCL, Flink…) | S3, Redshift, OpenSearch, HTTP endpoint |
| **Gestión** | Tú gestionas shards, consumers, checkpoints | Serverless — AWS gestiona todo |
| **Caso de uso** | Múltiples consumers distintos sobre el mismo stream | Quieres datos en S3/Redshift sin código |

**Analogía DevOps:**
- KDS ≈ **Kafka topic** — tú decides quién consume, cómo y cuándo
- Firehose ≈ **Logstash → S3** — pipeline managed, configuras y ya

---

## Conceptos clave de KDS

### Shard
Unidad de capacidad de un stream. Cada shard tiene:
- **Entrada:** 1 MB/seg, 1.000 records/seg
- **Salida:** 2 MB/seg (compartida entre consumers)

Un stream con 2 shards tiene 2 MB/seg entrada, 4 MB/seg salida.

### Partition Key
String que determina a qué shard va un record. KDS aplica MD5 hash y mapea al rango del shard. Clave para distribuir carga uniformemente: una partition key por entidad (userId, deviceId…), no un valor constante.

### Sequence Number
Identificador único y ordenado por shard que KDS asigna a cada record. No es global — cada shard tiene su propia secuencia. Permite reproducir eventos desde un punto concreto.

### Consumer
Aplicación que lee del stream. Puede ser Lambda, EC2/ECS con KCL, Kinesis Data Analytics, o Firehose mismo. Cada consumer tiene su propio puntero (iterator) — leer no destruye el record.

### Retención
Por defecto 24 horas. Configurable hasta 365 días (Extended Data Retention, coste adicional). Permite replay de eventos históricos sin infraestructura adicional.

---

## Enhanced Fan-Out

Sin EFO, el límite de 2 MB/seg por shard se **comparte** entre todos los consumers del shard.

Con Enhanced Fan-Out, cada consumer registrado obtiene **2 MB/seg dedicados** usando HTTP/2 push (en lugar de polling). Ideal cuando tienes 3+ consumers sobre el mismo stream y la latencia importa.

```
Sin EFO (2 shards, 3 consumers):
  Consumer A ─┐
  Consumer B ─┼── comparten 4 MB/seg total de salida
  Consumer C ─┘

Con EFO (2 shards, 3 consumers):
  Consumer A ── 4 MB/seg dedicados
  Consumer B ── 4 MB/seg dedicados
  Consumer C ── 4 MB/seg dedicados
```

Coste: $0.015 por hora de consumer registrado + $0.013 por GB leído.

---

## KDS vs Firehose vs SQS — Tabla de decisión

| Necesidad | Servicio | Por qué |
|---|---|---|
| Múltiples consumers distintos sobre el mismo stream | **KDS** | Retención + múltiples iterators independientes |
| Datos en S3/Redshift sin gestión de consumers | **Firehose** | Managed delivery, sin código consumer |
| Cola punto a punto, procesamiento async | **SQS** | Message queue, un consumer consume y borra |
| Procesamiento SQL/Flink en tiempo real | **Kinesis Data Analytics** | KDA sobre KDS |
| Ecosistema Kafka existente | **MSK** | Kafka gestionado, APIs compatibles |

**Regla práctica:**
- ¿Necesitas que múltiples sistemas distintos procesen el mismo evento simultáneamente? → **KDS**
- ¿Solo quieres persistir datos en S3 o cargarlos en Redshift? → **Firehose**
- ¿Cola de tareas donde el consumer destruye el mensaje? → **SQS**

---

## Capacidad y coste rápido

```
1 shard:
  Entrada:  1 MB/seg   |  1.000 records/seg
  Salida:   2 MB/seg   (compartida, sin EFO)
  Coste:    $0.015/hora por shard + $0.014 por 1M records

Ejemplo — 2 shards:
  Entrada total:  2 MB/seg
  Salida total:   4 MB/seg
  Coste base:     $0.03/h ≈ $0.72/día
```

Firehose: sin coste de shards. Pagas $0.029 por GB ingestado (primeros 500 TB/mes).

---

## Arquitectura típica

```
IoT / App / Logs
      │
      ▼
Kinesis Data Streams (KDS)
      │
      ├──► Lambda          (alertas en tiempo real)
      ├──► KDA / Flink     (analytics en tiempo real)
      └──► Firehose        (archivado en S3)
                │
                ▼
               S3  ──► Athena (queries ad-hoc)
```

Un stream, múltiples consumers. Cada uno a su velocidad, sin interferencia.
