# Lab 01 — Scenarios: Lambda en decisiones de arquitectura

## Scenario 1: Lambda vs ECS vs Fargate — ¿Cuándo cada uno?

**Contexto:** Tu equipo necesita procesar thumbnails de imágenes subidas por usuarios.

| Criterio | Lambda | ECS Fargate | EC2 |
|----------|--------|-------------|-----|
| Duración del proceso | ≤15 min ✓ | Ilimitada | Ilimitada |
| RAM necesaria | ≤10 GB ✓ | ≤120 GB | Sin límite |
| Frecuencia | Variable/bursty ✓ | Alta y constante | Constante |
| Cold start tolerable | Sí ✓ | No aplica | No aplica |
| Gestión de infraestructura | Ninguna ✓ | Mínima | Alta |
| Coste en idle | $0 ✓ | Mínimo (puede escalar a 0) | Fijo |

**Decisión para thumbnails:**
- Imágenes ≤5 MB, proceso <5s → **Lambda** (bursty, sin estado, barato)
- Videos de 4K, proceso >15 min → **ECS Fargate** (duración, RAM)
- Procesamiento constante 24/7 de alta frecuencia → **ECS Fargate** (más barato que Lambda a escala)

**El punto de inflexión Lambda → Fargate en coste:**
```
Lambda:  1M invocaciones × 1s × 512MB = ~$8/mes
Fargate: 1 tarea × 0.25vCPU × 0.5GB RAM × 730h = ~$7/mes

Si tienes >1M invocaciones/mes y tiempo de proceso >100ms, Fargate puede ser más barato.
El calculador AWS confirma el break-even para cada caso.
```

---

## Scenario 2: Cold Start en funciones de latencia crítica

**Contexto:** API de pagos con SLA de p99 < 200ms. Lambda actual tiene p99 de 800ms.

**Diagnóstico:**
```
P99 desglosado:
  ├─ Cold start (Init duration): 650ms  ← EL PROBLEMA
  │    ├─ Runtime init (Python): 50ms
  │    └─ Tu init code (conexiones, config): 600ms
  └─ Handler execution: 150ms
```

**Opciones:**

| Solución | Reduce cold start | Coste | Complejidad |
|----------|-------------------|-------|-------------|
| Provisioned Concurrency | Elimina (≈0ms init) | +30-50% sobre compute | Baja |
| Optimizar init code | Parcial | $0 | Media |
| Reducir package size | Parcial | $0 | Baja |
| Cambiar a Rust/Go runtime | Significativa | $0 | Alta |
| Migrar a ECS (siempre warm) | Elimina | Mayor coste idle | Media |

**Recomendación:** Para APIs síncronas con SLA estricto:
1. Primero optimiza el init code (elimina imports innecesarios, lazy loading)
2. Si no es suficiente, añade Provisioned Concurrency en el alias de producción
3. Solo migra a ECS si el tráfico es alto y constante (Fargate más barato a escala)

---

## Scenario 3: Exactly-once con SQS + Lambda idempotency

**Contexto:** Sistema de cobros. Un mensaje en SQS puede procesarse más de una vez (at-least-once delivery). El doble cobro es inaceptable.

**El problema:**
```
SQS Standard = at-least-once delivery
  → Un mensaje puede recibirse 2 veces si Lambda falla después de procesar
    pero antes de confirmar (delete) el mensaje

Lambda + SQS ESM = Lambda confirma (borra) el mensaje SOLO si retorna sin error
  → Si Lambda procesa el cobro pero lanza excepción, SQS reintenta
  → El cobro ya se hizo → DOBLE COBRO
```

**Solución: Idempotency token**

```python
import boto3
import hashlib

dynamodb = boto3.client('dynamodb')

def handler(event, context):
    for record in event['Records']:
        message_id = record['messageId']  # único en SQS
        
        # Intentar "reservar" este message_id en DynamoDB
        try:
            dynamodb.put_item(
                TableName='ProcessedPayments',
                Item={
                    'messageId': {'S': message_id},
                    'processedAt': {'S': datetime.utcnow().isoformat()}
                },
                ConditionExpression='attribute_not_exists(messageId)'
                # Falla si ya existe → ya procesado → no cobrar
            )
        except dynamodb.exceptions.ConditionalCheckFailedException:
            # Ya procesado — skip silenciosamente
            continue
        
        # Procesar cobro solo si DynamoDB aceptó el token
        process_payment(record['body'])
```

**Opción alternativa:** Lambda Powertools Idempotency decorator (Python/TypeScript).

---

## Scenario 4: Coste Lambda vs EC2 para workloads variables

**Contexto:** Pipeline de ML que procesa datos de usuarios. Tráfico varía 10x entre horas pico y valle.

```
Tráfico variable:
  Pico:  100 req/s × 2s × 1GB = 200 GB-s/s
  Valle: 10 req/s  × 2s × 1GB = 20 GB-s/s

Lambda:
  Total mensual ≈ (pico 4h/día × 200 GB-s/s + valle 20h × 20 GB-s/s) × 30 días
               ≈ (2.88M + 43.2M) GB-s × $0.0000167 ≈ $770/mes

EC2 (instancia fija para pico):
  r6g.xlarge (4 vCPU, 32GB): $0.2016/h × 730h = $147/mes
  → Pero desperdicia 80% de capacidad en horas valle

EC2 con Auto Scaling (target tracking p90):
  Instancias: 2 mínimo, 10 máximo
  Coste promedio: ~$350/mes

Conclusión para este caso: EC2 Auto Scaling gana en coste puro,
  pero Lambda gana en operaciones (0 gestión de fleet, 0 patching).
```

**Regla práctica:**
- Tráfico muy irregular (ratio pico/valle > 10x) → Lambda
- Tráfico alto y predecible → EC2 con Savings Plans o Fargate Spot
- Decisión final: incluir el coste de operaciones en el análisis, no solo el compute

---

## Anti-patrón: Lambda → Lambda síncrono

```
# ❌ ANTI-PATRÓN
def handler(event, context):
    lambda_client = boto3.client('lambda')
    
    # Llama a otra Lambda y espera respuesta
    response = lambda_client.invoke(
        FunctionName='lambda-downstream',
        InvocationType='RequestResponse',  # Síncrono
        Payload=json.dumps(event)
    )
    
    return json.loads(response['Payload'].read())
```

**Problemas:**
1. Pagas por el tiempo de espera en `lambda-upstream` (idle billing)
2. Si `lambda-downstream` falla, `lambda-upstream` también falla
3. La concurrencia de `lambda-upstream` está ocupada esperando

**Alternativas:**
- Si necesitas resultado inmediato → Step Functions Express (orquestación con estado)
- Si puedes procesar async → SQS entre funciones
- Si es un flujo complejo → Step Functions Standard

---

## Referencias

- [Lambda best practices](https://docs.aws.amazon.com/lambda/latest/dg/best-practices.html)
- [Lambda Power Tuning](https://github.com/alexcasalboni/aws-lambda-power-tuning)
- [Lambda Powertools](https://docs.powertools.aws.dev/lambda/python/)
