# Escenarios: ECS + EventBridge + Step Functions

## Escenario 1: Procesamiento en batch (múltiples documentos simultáneos)

**Situación:** 500 documentos llegan al mismo tiempo (carga de documentos legales al final del mes fiscal).

**Comportamiento automático:**
- EventBridge genera 500 eventos → Step Functions inicia 500 ejecuciones paralelas
- Cada ejecución lanza su propia Fargate Task
- ECS Cluster en modo Fargate: sin límite de capacidad predefinida, AWS aprovisiona bajo demanda
- Tiempo: si OCR tarda 5 minutos, todos los 500 documentos estarán listos en ~5-10 minutos (paralelo)

**Sin este diseño (procesamiento serial):** 500 × 5min = 2.500 minutos = 41 horas.

**Coste del pico:** 500 tasks × 2 vCPU × 5min × $0.04048/vCPU-hora = $16.87 para el batch completo.

**Limitación:** si los 500 documentos son PDFs de 200 páginas cada uno, 500 Tasks simultáneas con 4GB RAM = 2TB RAM total aprovisionada en Fargate. AWS tiene cuotas por región (por defecto: 100 tasks simultáneas por cuenta). Ajustar quota en AWS Support.

---

## Escenario 2: Documentos corruptos o ilegibles

**Situación:** Se sube un PDF corrupto o una imagen con mala calidad (OCR devuelve <10% de confianza).

**Flujo con umbral de confianza:**
```
ValidarExtraccion:
  Choice:
    - confidence >= 0.85 → RegistrarCompletado (automático)
    - confidence >= 0.50 → EnviarARevisionManual (operador revisa)
    - confidence < 0.50  → DocumentoIlegible (notificar al usuario para que suba de nuevo)
```

**Implementación adicional en el Choice state:**
```json
{
  "Type": "Choice",
  "Choices": [
    {
      "Variable": "$.extraccion.confidence",
      "NumericGreaterThanEquals": 0.85,
      "Next": "RegistrarCompletado"
    },
    {
      "Variable": "$.extraccion.confidence",
      "NumericGreaterThanEquals": 0.50,
      "Next": "EnviarARevisionManual"
    }
  ],
  "Default": "DocumentoIlegible"
}
```

---

## Escenario 3: El operador de revisión manual hace callback

**Situación:** Un documento va a `EnviarARevisionManual`. El operador ve el documento en el dashboard y aprueba/rechaza.

**Dashboard (aplicación web simple):**
```javascript
// 1. Obtener documentos pendientes de revisión
const pendientes = await sqs.receiveMessage({
  QueueUrl: REVISION_QUEUE_URL,
  MaxNumberOfMessages: 10,
  VisibilityTimeout: 3600
});

// 2. Operador revisa y aprueba
async function aprobar(message) {
  const { taskToken, doc_id, extraccion } = JSON.parse(message.Body);

  // Callback a Step Functions
  await sfn.sendTaskSuccess({
    taskToken,
    output: JSON.stringify({
      doc_id,
      revision_status: 'aprobado',
      campos_corregidos: extraccion.campos,
      revisor: 'operador-1'
    })
  });

  // Borrar de la cola
  await sqs.deleteMessage({ QueueUrl: REVISION_QUEUE_URL, ReceiptHandle: message.ReceiptHandle });
}

// 3. Operador rechaza (documento no procesable)
async function rechazar(message, motivo) {
  const { taskToken } = JSON.parse(message.Body);
  await sfn.sendTaskFailure({
    taskToken,
    error: 'DocumentoRechazado',
    cause: motivo
  });
}
```

---

## Escenario 4: Por qué EventBridge y no S3 trigger directo a Step Functions

S3 puede invocar Lambda directamente. Pero **S3 no puede invocar Step Functions directamente**.

El flujo sin EventBridge sería:
```
S3 trigger → Lambda → StartExecution (Step Functions)
```

Con EventBridge:
```
S3 notification → EventBridge → Step Functions (sin Lambda)
```

**Ventajas del enfoque EventBridge:**
- **Sin Lambda intermediaria:** menos código que mantener, menos coste
- **Múltiples targets:** el mismo evento puede ir a Step Functions + CloudWatch + Slack (3 destinos, 0 código)
- **Filtros declarativos:** solo procesar PDFs en `/incoming/`, ignorar thumbnails (<10KB) — todo en la regla sin código
- **Input transformation:** el evento S3 se reformatea al payload que espera Step Functions en la propia regla
- **Audit:** EventBridge Archive guarda todos los eventos (útil si hay que reproducir el procesamiento de un documento)

**Cuándo usar Lambda intermediaria:** si necesitas validación compleja antes de iniciar Step Functions (ej: deduplicación, enriquecimiento con datos externos).
