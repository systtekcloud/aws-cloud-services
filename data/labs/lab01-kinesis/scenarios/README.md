# Escenarios SAA-C03 — Kinesis

> 5 escenarios de examen con explicación detallada y tablas de decisión.

---

## Escenario 1: Múltiples consumers sobre el mismo evento

**Pregunta:** Una empresa procesa transacciones financieras. Cada transacción debe ser procesada simultáneamente por: (1) sistema antifraude, (2) sistema contable, (3) pipeline de auditoría. ¿Qué servicio usar?

**A)** SQS Standard Queue
**B)** SQS FIFO Queue
**C)** Kinesis Data Streams
**D)** SNS con 3 suscriptores SQS

**Respuesta: C — Kinesis Data Streams**

**Por qué:**
- SQS: el primer consumer que lee el mensaje lo "consume" — los otros consumers no lo ven (a menos que uses visibility timeout, pero no es para múltiples consumers simultáneos).
- SNS + SQS fan-out: válido, pero no preserva el orden ni permite replay. Si el sistema antifraude falla, el mensaje se pierde para él.
- KDS: retención 24h+, cada consumer tiene su propio shard iterator, todos leen el mismo record de forma independiente. Si el antifraude falla, puede volver a leer desde cualquier punto dentro de la ventana de retención.

**Cuándo SNS+SQS es mejor:** cuando los consumers son completamente independientes, no necesitas orden, y no necesitas replay. Para este caso de retención + replay + orden → KDS.

---

## Escenario 2: Ingesta de logs hacia S3 sin gestión de infraestructura

**Pregunta:** Una startup quiere enviar logs de su aplicación web directamente a S3 para análisis posterior con Athena. El equipo es pequeño y no quiere gestionar consumers, shards ni checkpoints. ¿Cuál es la solución más sencilla?

**A)** Kinesis Data Streams + Lambda que escribe en S3
**B)** Kinesis Data Firehose con destino S3
**C)** Kinesis Data Streams + Kinesis Data Analytics + S3
**D)** MSK (Managed Kafka) + Kafka Connect hacia S3

**Respuesta: B — Kinesis Data Firehose**

**Por qué:**
- Firehose es managed delivery — no gestionas consumers, shards, iterators ni checkpoints.
- Soporta prefijos con fecha automáticamente (`!{timestamp:yyyy}/…`), ideal para particionado en Athena.
- Buffer configurable (60s o 1MB): near-real-time es suficiente para análisis posterior.
- KDS + Lambda funciona pero requiere gestionar Lambda concurrency, error handling, batching.
- MSK es para equipos con ecosistema Kafka existente — sobra para este caso.

**Trampa del examen:** "el equipo no quiere gestionar" → siempre apunta a servicios managed. Firehose > KDS cuando hay un único consumer que escribe en S3/Redshift.

---

## Escenario 3: Enhanced Fan-Out — cuándo activarlo

**Pregunta:** Una empresa tiene un KDS con 4 shards procesando datos de telemetría. Tienen 6 consumers Lambda distintos. Los consumidores empiezan a sufrir latencia elevada y throttling en GetRecords. ¿Cuál es la causa y la solución?

**A)** Aumentar el número de shards a 8
**B)** Activar Enhanced Fan-Out para los consumers críticos
**C)** Migrar a SQS para reducir latencia
**D)** Aumentar la retención del stream

**Respuesta: B — Enhanced Fan-Out**

**Por qué:**
Sin EFO, los 6 consumers comparten el límite de salida de 2 MB/seg por shard. Con 4 shards, el total de salida es 8 MB/seg compartidos entre 6 consumers → ~1.3 MB/seg por consumer.

Con EFO, cada consumer registrado obtiene 2 MB/seg dedicados por shard (HTTP/2 push). Con 4 shards, cada consumer EFO obtiene 8 MB/seg dedicados.

- Opción A (más shards): aumenta capacidad de entrada también, innecesario si el problema es de salida.
- Opción C (SQS): no preserva el orden, no permite múltiples consumers sobre el mismo mensaje.
- Opción D (retención): no afecta al throughput.

**Coste EFO:** $0.015/hora por consumer registrado + $0.013/GB leído. Activar solo para consumers que lo necesiten.

---

## Escenario 4: KDS vs SQS para procesamiento async

**Pregunta:** Una aplicación de e-commerce necesita procesar pedidos de forma asíncrona. Cada pedido es procesado por un único worker. No necesita replay, no hay múltiples consumers, y el orden no es crítico. ¿KDS o SQS?

**A)** Kinesis Data Streams — mayor throughput
**B)** SQS Standard Queue — procesamiento punto a punto
**C)** Kinesis Data Firehose — managed delivery
**D)** SQS FIFO Queue — orden garantizado

**Respuesta: B — SQS Standard Queue**

**Por qué:**
- Un único consumer: SQS es la elección natural. Consumes y borras.
- No necesitas replay: la retención de KDS es un coste innecesario.
- Orden no crítico: SQS Standard es más barato y más simple que FIFO.
- KDS requiere gestionar shards, iterators, checkpoints — complejidad innecesaria para una cola punto a punto.

**Regla práctica:** Si es una cola de tareas (un producer → un consumer, procesar y olvidar) → **SQS**. Si es un stream de eventos (múltiples consumers, replay, orden) → **KDS**.

---

## Escenario 5: Transformación en tiempo real

**Pregunta:** Un stream de métricas en KDS necesita enriquecerse con datos de referencia y filtrarse (eliminar registros con valor null) antes de persistirse en S3. ¿Cuál es el mejor enfoque?

**A)** KDS → Lambda con trigger → S3 directo
**B)** KDS → Firehose con transformación Lambda → S3
**C)** KDS → Kinesis Data Analytics → S3
**D)** KDS → EC2 consumer → S3

**Respuesta: B — Firehose con transformación Lambda**

**Por qué:**
- Firehose + Lambda: managed batching, reintentos automáticos, buffer configurable. La Lambda recibe batches de Firehose, transforma/filtra y devuelve. Error handling incluido.
- Lambda trigger directo en KDS: tienes que gestionar batching, concurrency, errores, reintentos. Más control pero más complejidad.
- KDA: válido para SQL/Flink en tiempo real, pero más caro ($0.11/KPU-hora) y más complejidad para transformaciones simples.
- EC2: gestión máxima, coste fijo, no recomendado para transformaciones simples.

**Cuándo Lambda trigger KDS > Firehose+Lambda:** cuando necesitas latencia milisegundos, lógica compleja, o no quieres pasar por Firehose.

---

## Tabla de decisión: KDS vs SQS vs SNS vs Firehose

| Criterio | KDS | SQS | SNS | Firehose |
|---|---|---|---|---|
| Múltiples consumers simultáneos | ✓ | ✗ (1 consumer) | ✓ (push) | ✗ |
| Orden garantizado | Por shard | Solo FIFO | ✗ | N/A |
| Replay (leer datos pasados) | ✓ (retención) | ✗ | ✗ | ✗ |
| Destino S3/Redshift managed | Con Firehose | ✗ | ✗ | ✓ |
| Latencia | Milisegundos | Milisegundos | Milisegundos | ~60 segundos |
| Gestión requerida | Media (shards) | Baja | Baja | Mínima |
| Precio base | $0.015/shard/h | $0.40/M msg | $0.50/M notif | $0.029/GB |

**Reglas mnemotécnicas:**
- "Replay + múltiples consumers + orden" → **KDS**
- "Cola punto a punto, procesar y olvidar" → **SQS**
- "Fanout push a N endpoints" → **SNS**
- "Destino S3/Redshift sin código consumer" → **Firehose**

---

## Enhanced Fan-Out — tabla de decisión

| Situación | Usar EFO |
|---|---|
| 1-2 consumers sobre el stream | No — comparten 2 MB/seg sin problema |
| 3+ consumers y latencia importa | Sí — cada consumer necesita ancho de banda dedicado |
| Consumer crítico con SLA estricto | Sí — garantiza throughput independiente |
| Consumer de baja prioridad (archivado) | No — no merece el coste adicional |

**Regla:** activa EFO por consumer, no para todos. El consumer de alertas críticas merece EFO; el consumer de archivado a S3 puede usar el throughput compartido.
