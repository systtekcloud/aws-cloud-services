# Escenarios SAA-C03 — Amazon MSK

> 3 escenarios de examen con tabla de decisión MSK vs Kinesis.

---

## Escenario 1: MSK para migración lift-and-shift de Kafka on-prem

**Pregunta:** Una empresa tiene una plataforma de e-commerce con Kafka on-prem. Tienen 50 microservicios producers/consumers que usan la API nativa de Kafka. Quieren migrar a AWS minimizando cambios de código y tiempo de migración. ¿Qué solución recomiendas?

**A)** Reescribir todos los producers/consumers para usar Kinesis Data Streams SDK
**B)** Usar Amazon MSK — migrar el cluster Kafka a AWS
**C)** Usar Amazon SQS para reemplazar los topics de Kafka
**D)** Usar Amazon SNS con fanout para reemplazar Kafka

**Respuesta: B — Amazon MSK**

**Por qué:**
- MSK expone la API nativa de Kafka. Los 50 microservicios solo necesitan cambiar la variable `bootstrap.servers` al endpoint de MSK. Cero cambios de código de negocio.
- Kinesis (A): Requeriría reescribir todos los producers y consumers — el SDK de KDS no es compatible con la API de Kafka. Meses de trabajo y alto riesgo.
- SQS (C): Cola punto a punto. No soporta múltiples consumer groups leyendo el mismo mensaje, no hay concepto de topic con retención, no hay particiones. Cambio arquitectural masivo.
- SNS (D): Pub/sub sin retención ni replay. No reemplaza Kafka.

**Clave del examen:** Cuando el enunciado menciona "ecosistema Kafka existente", "microservicios con API Kafka", o "migración desde Kafka on-prem" → **MSK es la respuesta correcta**.

---

## Escenario 2: MSK vs Kinesis — sistema nuevo de telemetría IoT

**Pregunta:** Una startup de IoT quiere construir un sistema de ingesta de datos de sensores desde cero en AWS. El equipo de ingeniería no tiene experiencia previa con Kafka. Necesitan:
- Ingerir 5.000 eventos/seg de 500 dispositivos
- Procesar en tiempo real con Lambda
- Archivar en S3 para análisis histórico
- Tres departamentos distintos consumiendo el mismo stream

¿Qué servicio de streaming elegir?

**A)** Amazon MSK con MSK Connect para S3 y Lambda trigger
**B)** Amazon MSK Serverless
**C)** Kinesis Data Streams + Firehose + Lambda trigger
**D)** Amazon SQS FIFO con multiple consumers

**Respuesta: C — Kinesis Data Streams + Firehose + Lambda trigger**

**Por qué:**
- El equipo no tiene experiencia Kafka → curva de aprendizaje de MSK (topics, partitions, consumer groups, offsets, ZooKeeper/KRaft) innecesaria.
- KDS tiene **integración nativa** con Lambda (trigger managed) y Firehose (delivery a S3 sin código).
- 5.000 eventos/seg con 2 shards = fácilmente gestionable. KDS escala shards con un comando.
- Tres consumers distintos: KDS soporta múltiples consumers independientes con su propio ShardIterator.
- MSK requeriría gestionar Kafka Connect para S3, configurar Lambda trigger MSK, consumer groups — todo más complejo sin ganancia real.

**SQS FIFO (D):** No soporta múltiples consumers independientes leyendo el mismo mensaje.

**Regla:** "Empezar desde cero en AWS, sin experiencia Kafka previa" → **Kinesis**.

---

## Escenario 3: MSK Connect vs Lambda para pipeline de datos

**Pregunta:** Una empresa tiene MSK con un topic de logs de aplicación recibiendo 100 MB/min. Necesitan:
1. Archivar todos los logs en S3 en formato JSON particionado por fecha/hora
2. Detectar errores críticos y enviar alerta a PagerDuty en < 2 segundos

¿Qué arquitectura usar para cada requisito?

**A)** Lambda para ambos
**B)** MSK Connect S3 Sink para el archivo, Lambda para las alertas
**C)** Kinesis Firehose para el archivo, Lambda para las alertas
**D)** MSK Connect para ambos

**Respuesta: B — MSK Connect S3 Sink + Lambda**

**Por qué:**

**Para el archivo (100 MB/min):**
- Lambda: cada Lambda invocation procesa un batch de mensajes → necesita subir a S3 manualmente → gestionar particionamiento por fecha/hora → gestionar errores de upload. A 100 MB/min con batchSize razonable serían cientos de invocaciones/minuto.
- MSK Connect S3 Sink: configuración declarativa. `path.format`, `partitioner.class=TimeBasedPartitioner` — cero código. Diseñado exactamente para este caso. Workers dedicados, alto throughput.

**Para las alertas (< 2 seg):**
- MSK Connect: latencia mínima de `rotate.interval.ms` (típicamente 60 seg). No apto para alertas sub-segundo.
- Lambda trigger MSK: latencia de milisegundos. Filtra `ERROR` level, llama a PagerDuty API. Lógica de negocio simple → Lambda ideal.

**Kinesis Firehose (C):** El source es MSK, no KDS. Firehose puede consumir desde KDS directamente, pero desde MSK requiere un puente (Lambda o MSK Connect). MSK Connect S3 Sink es más directo.

---

## Tabla de decisión completa: MSK vs Kinesis vs SQS vs SNS

| Criterio | MSK | Kinesis Data Streams | SQS | SNS |
|---|---|---|---|---|
| **API** | Kafka nativa | AWS SDK propietario | AWS SDK | AWS SDK |
| **Migración desde Kafka** | Sin cambios de código | Reescritura completa | Reescritura completa | No aplica |
| **Múltiples consumers independientes** | Sí (consumer groups) | Sí (ShardIterators) | No (1 consumer destruye mensaje) | Sí (subscriptions) |
| **Retención de mensajes** | Configurable (log.retention) | 1–365 días | Hasta 14 días | No (no hay retención) |
| **Replay de mensajes** | Sí (por offset) | Sí (ShardIterator) | No | No |
| **Orden garantizado** | Por partición | Por shard | SQS FIFO por grupo | No |
| **Throughput** | Sin límite práctico | 1MB/seg/shard | Sin límite práctico | Sin límite práctico |
| **Integración Lambda** | Lambda trigger MSK | Lambda trigger KDS (nativo) | Lambda trigger SQS (nativo) | Lambda subscription |
| **Integración Firehose** | Via MSK Connect | Directo (native) | No | No |
| **Gestión requerida** | Media (topics, partitions) | Baja (shards) | Muy baja | Muy baja |
| **Ecosistema** | Kafka Connect, Kafka Streams, Flink | KDA, Firehose, KCL | DLQ, delay queues | Fan-out, mobile push |
| **Caso de uso principal** | Migración Kafka, plataforma de datos madura | Streaming AWS nativo nuevo | Cola async punto a punto | Notificaciones fan-out |

---

## Cuándo Kafka Connect + MSK vs Lambda consumer + MSK

```
Decide según el tipo de procesamiento:

  Mover datos a otro sistema         → MSK Connect (S3, DynamoDB, OpenSearch)
  Lógica de negocio por mensaje      → Lambda
  Transformaciones complejas         → Kafka Streams / MSK
  Analytics en tiempo real           → Lambda + KDA / Flink on MSK
  Alta latencia tolerable (segundos) → MSK Connect
  Baja latencia requerida (< 1 seg)  → Lambda
```
