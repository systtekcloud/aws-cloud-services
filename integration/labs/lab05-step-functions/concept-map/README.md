# Step Functions — Concept Map

## ¿Qué es Step Functions?

AWS Step Functions es un servicio de **orquestación de workflows**. Define flujos de trabajo como máquinas de estado (State Machines) en ASL (Amazon States Language). Cada paso del flujo es un estado. Step Functions gestiona los reintentos, timeouts, el estado entre pasos y la auditoría de cada ejecución.

---

## Orquestación vs Coreografía

```
Coreografía (EventBridge/SNS):
  Cada servicio sabe qué hacer cuando recibe un evento
  No hay coordinador central
  + Simple de implementar
  + Desacoplado
  - Difícil de depurar cuando algo falla
  - No hay visibilidad del flujo completo

Orquestación (Step Functions):
  Una state machine centraliza el flujo
  Cada paso invoca un servicio y espera el resultado
  + Visibilidad completa del flujo
  + Retry y error handling declarativos
  + Auditoría de cada ejecución
  - Acoplamiento al orquestador
  - Coste adicional por transición de estado
```

**Regla práctica:** 3+ pasos con estado, retry complejo, o necesidad de auditoría → Step Functions. Notificaciones simples o fan-out → EventBridge/SNS.

---

## Standard vs Express Workflows

| Aspecto | Standard | Express |
|---------|----------|---------|
| Modelo de ejecución | Exactly-once | At-least-once |
| Duración máxima | 1 año | 5 minutos |
| Throughput | 2.000 exec/s (por cuenta) | 100.000 exec/s |
| Historial | Completo en consola (90 días) | Solo CloudWatch Logs |
| Uso típico | Procesos de negocio, workflows críticos | Microservicios de alta freq, IoT |
| Precio | $0.025 por 1.000 transiciones | $0.00001 por ejecución + $0.00001 por duración (GB-s) |

---

## Estados disponibles (ASL)

```
Task      — Invoca un servicio (Lambda, ECS, DynamoDB, SQS, etc.)
Choice    — Bifurcación condicional (como switch/case)
Wait      — Espera N segundos o hasta timestamp
Parallel  — Ejecuta branches en paralelo, espera a que todos terminen
Map       — Itera sobre un array, procesa cada item (en paralelo o en serie)
Pass      — Pasa el input al output sin hacer nada (útil para debug)
Succeed   — Termina con éxito explícito
Fail      — Termina con error explícito
```

---

## ASL básico — anatomía

```json
{
  "Comment": "Workflow de procesamiento de pedido",
  "StartAt": "ValidarPedido",
  "States": {
    "ValidarPedido": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:...:function:validar-pedido",
      "Next": "ProcesarPago",
      "Retry": [{
        "ErrorEquals": ["Lambda.ServiceException", "Lambda.TooManyRequestsException"],
        "IntervalSeconds": 2,
        "MaxAttempts": 3,
        "BackoffRate": 2
      }],
      "Catch": [{
        "ErrorEquals": ["ValidacionError"],
        "Next": "PedidoRechazado"
      }]
    },
    "ProcesarPago": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sqs:sendMessage.waitForTaskToken",
      "Parameters": {
        "QueueUrl": "https://sqs...",
        "MessageBody": {
          "taskToken.$": "$$.Task.Token",
          "pedido.$": "$.pedido_id"
        }
      },
      "Next": "EnviarConfirmacion"
    },
    "EnviarConfirmacion": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:...:function:enviar-email",
      "End": true
    },
    "PedidoRechazado": {
      "Type": "Fail",
      "Error": "PedidoInvalido",
      "Cause": "La validación del pedido falló"
    }
  }
}
```

---

## Retry con backoff exponencial

```json
"Retry": [{
  "ErrorEquals": ["States.TaskFailed"],
  "IntervalSeconds": 2,    // Primer retry: espera 2s
  "MaxAttempts": 3,        // Máximo 3 reintentos
  "BackoffRate": 2,        // Cada retry espera el doble: 2s, 4s, 8s
  "MaxDelaySeconds": 300   // Máximo 5 min entre retries (cap)
}]
```

---

## waitForTaskToken — integración con sistemas externos

Permite que Step Functions espere (de forma asíncrona) a que un sistema externo llame de vuelta con el token de tarea. Fundamental para long-running tasks.

```
Step Functions genera taskToken
    │
    ▼
Envía a SQS/API/Lambda (con el token)
    │
    ▼ (sistema externo procesa, puede tardar horas)
Sistema llama:
  aws stepfunctions send-task-success \
    --task-token "TOKEN" \
    --task-output '{"resultado": "ok"}'
    │
    ▼
Step Functions continúa al siguiente estado
```

---

## Step Functions vs alternativas

| Caso | Herramienta | Por qué |
|------|-------------|---------|
| Workflow 3+ pasos con retry | Step Functions Standard | Auditoría, exactly-once |
| 100K workflows/s simples | Step Functions Express | Throughput alto |
| Notificar múltiples sistemas | EventBridge/SNS | Fan-out simple |
| Job batch largo (>1h) | Step Functions + ECS Task | waitForTaskToken + Fargate |
| DAG de tareas ML | SageMaker Pipelines | Integración nativa ML |
| Workflows complejos multi-equipo | Apache Airflow (MWAA) | DAGs Python, UI rica |

---

## Pricing

```
Standard:
  $0.025 por 1.000 transiciones de estado
  Ejemplo: workflow de 10 estados × 1M ejecuciones/mes = $250

Express (async):
  $0.000001 por invocación
  + $0.00001 por GB-s de duración
  Ejemplo: 100M invocaciones de 1s con 64MB = ~$0.16/mes
```
