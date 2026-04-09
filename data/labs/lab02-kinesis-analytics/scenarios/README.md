# Escenarios SAA-C03 — Kinesis Data Analytics

> 3 escenarios de examen con explicación detallada y tablas de decisión.

---

## Escenario 1: KDA vs Lambda para procesamiento de streams

**Pregunta:** Una empresa recibe datos de telemetría de 10.000 vehículos en KDS. Necesita calcular la velocidad promedio por zona geográfica en ventanas deslizantes de 5 minutos, y detectar si alguna zona supera el límite de velocidad promedio. ¿Qué servicio usar para el procesamiento?

**A)** Lambda con trigger KDS
**B)** Kinesis Data Analytics con SQL
**C)** Glue Streaming ETL
**D)** EC2 con KCL (Kinesis Client Library)

**Respuesta: B — Kinesis Data Analytics con SQL**

**Por qué:**
- El requisito clave es **ventana deslizante de 5 minutos** con **aggregación por grupo** (zona geográfica). Esto es exactamente para lo que está diseñado Flink/KDA.
- Lambda: no tiene estado interno. Para una sliding window necesitarías DynamoDB para acumular los datos de 5 minutos por zona, gestionar la expiración, calcular manualmente el promedio. Complejo y propenso a errores.
- KDA SQL: `GROUP BY zona, STEP(ROWTIME BY INTERVAL '5' MINUTE)` — dos líneas de SQL.
- Glue Streaming: válido pero más orientado a ETL que a analytics en tiempo real con alertas.
- EC2 + KCL: máxima flexibilidad pero gestión completa del cluster.

**Trampa del examen:** Si el enunciado menciona "ventana temporal", "promedio en los últimos N minutos", o "agregación sobre stream" → **KDA**.

---

## Escenario 2: Tumbling vs Sliding Window

**Pregunta:** Una empresa de e-commerce quiere monitorizar su sistema de pagos con dos métricas:
1. Total de transacciones por hora para el informe de negocio
2. Tasa de errores en los últimos 5 minutos actualizada cada minuto para alertas operacionales

¿Qué tipo de ventana usar para cada métrica?

**A)** Tumbling window para ambas
**B)** Sliding window para ambas
**C)** Tumbling para el informe por hora, Sliding para la tasa de errores
**D)** Session window para ambas

**Respuesta: C — Tumbling para el informe, Sliding para alertas**

**Por qué:**

```
Métrica 1 — Informe por hora (Tumbling):
  ─[   00:00-01:00   ]─[   01:00-02:00   ]─[   02:00-03:00   ]─
  Sin solapamiento. Cada hora es independiente.
  "¿Cuántas transacciones hubo entre las 14:00 y las 15:00?"

Métrica 2 — Tasa de errores en últimos 5 min (Sliding):
  ──[13:55-14:00]──
      ──[13:56-14:01]──
          ──[13:57-14:02]──
  Avanza cada minuto, ventana de 5 min.
  "¿Cuál es la tasa de error en este momento, mirando los últimos 5 minutos?"
```

**Regla:**
- **Tumbling:** periodos discretos sin solapamiento — informes, facturas, resúmenes por hora/día
- **Sliding:** métricas continuas con contexto histórico — alertas, dashboards, detección de tendencias

---

## Escenario 3: Cuándo KDA Anomaly Detection vs threshold fijo

**Pregunta:** Un equipo de plataforma quiere detectar comportamiento anómalo en las métricas de sus microservicios. El tráfico varía significativamente: de noche hay un 90% menos de peticiones que durante el pico del día. Un threshold fijo de "error_rate > 5%" generaría demasiados falsos positivos por la noche. ¿Qué solución usar?

**A)** CloudWatch Alarm con threshold fijo de error_rate > 5%
**B)** CloudWatch Anomaly Detection sobre la métrica de error rate
**C)** KDA con RANDOM_CUT_FOREST sobre el stream de métricas
**D)** Lambda que calcula el percentil 99 y alerta si supera 3 desviaciones estándar

**Respuesta: C — KDA con RANDOM_CUT_FOREST**

**Por qué:**
- CloudWatch Alarm con threshold fijo: genera falsos positivos de noche (tráfico bajo → pocos errores son "mayor porcentaje").
- CloudWatch Anomaly Detection: válido y más sencillo, pero trabaja métrica a métrica. No puede correlacionar CPU + latencia + error_rate juntos como variables multivariadas.
- KDA RANDOM_CUT_FOREST: aprende el comportamiento multivariado. A las 3:00 AM "sabe" que el patrón normal es X, y detecta desviaciones respecto a ese patrón. No necesitas definir umbrales.
- Lambda con percentil: requiere estado externo, lógica manual, no escala a múltiples variables correlacionadas.

**Cuándo CloudWatch Anomaly Detection es suficiente:**
- Una métrica a la vez
- Datos ya en CloudWatch (no en KDS)
- Latencia de detección de minutos es aceptable
- Equipo no quiere gestionar KDA

**Cuándo KDA RANDOM_CUT_FOREST:**
- Stream de datos personalizado (no métricas AWS nativas)
- Necesitas correlacionar múltiples variables
- Latencia sub-segundo en la detección
- Patrón de tráfico muy variable (día/noche, seasonal)

---

## Tabla de decisión: KDA vs otras opciones de procesamiento de streams

| Necesidad | Solución | Por qué |
|---|---|---|
| Agregación en ventanas temporales | **KDA** | Nativo: tumbling/sliding/session |
| Transformación simple registro a registro | **Lambda** | Sin estado, sin ventanas |
| Enriquecimiento con datos S3/DynamoDB | **Lambda** | Integración AWS nativa |
| Detección de anomalías multivariada | **KDA RANDOM_CUT_FOREST** | Algoritmo integrado |
| Delivery a S3/Redshift | **Firehose** | Managed, sin código consumer |
| Join entre dos streams | **KDA** | Stream join nativo en Flink |
| Ecosistema Kafka / Flink existente | **MSK + Flink propio** | Portabilidad, evita vendor lock |
| Batch sobre datos históricos | **Glue / EMR** | KDA es solo para streaming |

---

## Ventanas temporales — resumen visual

```
Datos: E1(00) E2(10) E3(20) E4(30) E5(40) E6(50) E7(60) E8(70)
       (segundos)

Tumbling (60s):
  [E1 E2 E3 E4 E5 E6]           [E7 E8 ...]
  Resultado cada 60s. Sin solapamiento.

Sliding (60s ventana, 30s slide):
  [E1 E2 E3 E4 E5 E6]
              [E4 E5 E6 E7 E8]
  Resultado cada 30s. Ventana cubre 60s atrás.

Session (gap=15s):
  [E1 E2 E3]  gap>15s  [E5 E6]  gap>15s  [E8]
  Agrupa eventos consecutivos. Fin cuando hay silencio >15s.
```
