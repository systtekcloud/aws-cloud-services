# Kinesis Data Analytics (Managed Apache Flink) — Mapa Conceptual

> **Módulo:** `data/labs/lab02-kinesis-analytics` | **Región:** eu-west-1

---

## Qué es Kinesis Data Analytics

Kinesis Data Analytics (ahora llamado **Amazon Managed Service for Apache Flink**) ejecuta aplicaciones Flink o SQL directamente sobre streams en tiempo real. Sin gestión de cluster — AWS gestiona workers, checkpoints, escalado y recuperación ante fallos.

```
Kinesis Data Streams / MSK
          │
          ▼
  Managed Apache Flink
  ┌─────────────────────────────┐
  │  Source  →  Operators  →  Sink  │
  │                             │
  │  - Aggregaciones            │
  │  - Joins entre streams      │
  │  - Detección anomalías      │
  │  - Enriquecimiento          │
  └─────────────────────────────┘
          │
          ▼
  KDS / Firehose / S3 / Lambda
```

**Serverless:** pagas por KPU (Kinesis Processing Unit). 1 KPU = 1 vCPU + 4 GB RAM. Precio: $0.11/KPU-hora.

---

## KDA vs Lambda para procesar KDS

| | KDA / Flink | Lambda |
|---|---|---|
| **Aggregaciones con ventanas** | Nativo (tumbling, sliding, session) | Manual — necesitas estado externo (DynamoDB) |
| **Joins entre streams** | Nativo | Muy complejo |
| **Stateful processing** | Nativo — checkpoints automáticos | Necesitas estado externo |
| **Transformación registro a registro** | Posible pero overkill | Ideal |
| **Integración AWS servicios** | Limitada (KDS, S3, Firehose) | Amplia (cualquier servicio AWS) |
| **Latencia** | Milisegundos | Milisegundos |
| **Coste base** | $0.11/KPU-hora (siempre encendido) | Solo por invocación |
| **Curva de aprendizaje** | Alta (Flink/SQL streaming) | Baja |

**Regla práctica:**
- ¿Necesitas ventanas temporales, joins entre streams, o estado complejo? → **KDA/Flink**
- ¿Es una transformación simple registro a registro o integración con otros servicios? → **Lambda**

---

## Conceptos Flink

### Source
Entrada de datos al pipeline. En KDA: `KinesisStreamsSource` (desde KDS) o `KafkaSource` (desde MSK). El source deserializa los bytes del stream en objetos Java/Scala/Python.

### Sink
Salida del pipeline. En KDA: `KinesisStreamsSink` (hacia KDS), `FileSink` (hacia S3), o `FlinkKinesisFirehoseProducer` (hacia Firehose). El sink serializa y escribe los resultados.

### Operator
Transformación sobre el stream: `map`, `filter`, `flatMap`, `keyBy`, `reduce`, `aggregate`. Los operadores se encadenan formando el DAG del job.

### Window — los 3 tipos

```
Tumbling Window (no solapadas):
  ─────[  60s  ]─────[  60s  ]─────[  60s  ]─────
  Cada ventana es independiente. Promedio por minuto.

Sliding Window (solapadas):
  ──[   60s   ]──
        ──[   60s   ]──
              ──[   60s   ]──
  Avanza cada 30s. Media móvil. Más granularidad.

Session Window (basadas en actividad):
  ──[eventos]──gap──[eventos]──gap──[eventos]──
  Agrupa eventos mientras haya actividad.
  Gap configurable (ej: inactividad > 5 min = nueva sesión).
```

**Cuándo usar cada una:**
- **Tumbling:** métricas por intervalo fijo (minuto, hora) — sin solapamiento
- **Sliding:** media móvil, alertas con contexto de tiempo continuo
- **Session:** análisis de sesiones de usuario, eventos con actividad variable

---

## Analogía DevOps

```
KDA/Flink ≈ Pipeline de CI/CD para datos en streaming

CI/CD pipeline:          Flink pipeline:
  Source code       →      Stream de eventos
  Build step        →      Operator (filter/map)
  Test step         →      Operator (aggregate/join)
  Deploy artifact   →      Sink (S3/KDS/Firehose)
  State between runs →     Checkpoints (estado Flink)
  Parallelism       →      Paralelismo por operador
```

Como un pipeline de Jenkins/GitHub Actions, pero en lugar de procesar código una vez, procesa un flujo continuo de eventos. Los checkpoints son como los artefactos de CI — permiten reanudar desde el último punto conocido si el job falla.

---

## Cuándo KDA tiene sentido

| Caso de uso | Por qué KDA |
|---|---|
| Promedio de temperatura por sensor en último minuto | Tumbling window — trivial en Flink SQL |
| Detección de anomalías sin threshold fijo | RANDOM_CUT_FOREST integrado |
| Join: enriquecer eventos con datos de referencia | Stream-to-stream join con ventana temporal |
| Conteo de errores HTTP 5xx por servicio en 30s | Sliding window + filter |
| Sesiones de usuario: tiempo en app por sesión | Session window |

**KDA NO tiene sentido para:**
- Transformaciones simples (añadir campo, cambiar formato) → Lambda
- Un único consumer que escribe en S3 → Firehose
- Procesamiento batch de datos históricos → Glue/EMR
