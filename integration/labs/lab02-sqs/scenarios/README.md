# Lab 02 — Scenarios: SQS en decisiones de arquitectura

## Scenario 1: ¿Standard o FIFO para mi caso de uso?

**Contexto:** Sistema de e-commerce con dos flujos distintos.

**Flujo A — Procesamiento de imágenes de productos:**
- 5.000 imágenes/hora a procesar
- El orden no importa
- Procesar 2 veces = mismo resultado (idempotente)
- → **Standard Queue**: throughput ilimitado, más barato

**Flujo B — Procesamiento de pedidos:**
- 500 pedidos/hora
- El orden importa (creación → pago → envío, en ese orden por pedido)
- No se puede duplicar el cobro
- → **FIFO Queue**: ordering por cliente (MessageGroupId = clienteId), deduplicación

---

## Scenario 2: Dimensionar Visibility Timeout correctamente

**Error común:** Visibility timeout < tiempo de procesamiento.

```
Ejemplo roto:
  VisibilityTimeout = 30s
  Lambda timeout     = 60s

¿Qué pasa?
  1. Lambda recibe el mensaje (30s de invisibilidad)
  2. Lambda procesa durante 31s (el timeout expiró en segundo 30)
  3. El mensaje vuelve a ser visible mientras Lambda aún procesa
  4. Otra Lambda recibe el mismo mensaje → DOBLE PROCESAMIENTO
```

**Regla:**
```
VisibilityTimeout >= Lambda timeout × 6

Lambda timeout = 60s → VisibilityTimeout = 360s mínimo

¿Por qué × 6? AWS recomienda este factor para absorber reintentos
y tiempo de overhead del servicio.
```

---

## Scenario 3: SQS como buffer ante picos de tráfico

**Problema:** API de notificaciones recibe 50.000 requests en 5 minutos durante una campaña de marketing. El servicio de email downstream aguanta 500 emails/minuto.

```
Sin SQS:
  50.000 requests → Servicio email → Se satura → 429 / timeouts / pérdida de emails

Con SQS:
  50.000 requests → [SQS Queue] → Servicio email a 500/min → procesa en ~100 min
                   (no pierde ni un email)
```

**Métricas a monitorizar:**
- `ApproximateAgeOfOldestMessage`: cuánto espera el mensaje más antiguo
- `ApproximateNumberOfMessagesVisible`: profundidad actual de la queue
- Si la edad sube mucho → escalar el consumer

---

## Scenario 4: DLQ como safety net, no como papelera

**Anti-patrón frecuente:** Configurar DLQ y olvidarse de ella.

```
Bad:
  maxReceiveCount = 3
  DLQ configurada
  No hay alarma ni proceso de revisión
  → Los mensajes se acumulan durante 14 días y se pierden

Good:
  maxReceiveCount = 3
  DLQ configurada
  Alarma CloudWatch: DLQ > 0 → alerta a PagerDuty/Slack
  Proceso documentado: cómo investigar y hacer redrive
  → Cada mensaje en DLQ = incidente investigado
```

**Proceso de gestión de DLQ:**
1. Alarma dispara → equipo investiga el mensaje en DLQ
2. Identificar la causa (bug en consumer, formato inesperado, dependencia caída)
3. Desplegar fix
4. `start-message-move-task` para redrive (reenvío a queue original)
5. Verificar que los mensajes se procesan correctamente
