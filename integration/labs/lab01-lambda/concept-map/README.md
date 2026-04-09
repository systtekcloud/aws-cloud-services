# Lambda — Concept Map

## ¿Qué es Lambda?

Lambda es **compute sin servidor**: ejecutas código sin gestionar instancias, sin pagar por tiempo idle. Pagas por el número de invocaciones y los GB-segundos de ejecución.

La analogía DevOps: Lambda ≈ una función en Vercel/Cloudflare Workers, pero con acceso completo al ecosistema AWS (IAM, VPC, CloudWatch, X-Ray) y sin las limitaciones de edge runtimes.

---

## Modelo de ejecución

```
Evento de entrada
      │
      ▼
┌─────────────────────────────────┐
│       Execution Environment     │
│  (microVM gestionada por AWS)   │
│                                 │
│  Runtime (Python/Node/Java/...) │
│         │                       │
│         ▼                       │
│      Handler()                  │
│      └── tu código              │
└─────────────────────────────────┘
      │
      ▼
Resultado / Error
```

### Ciclo de vida del Execution Environment

```
INIT phase
  ├─ Descarga código/imagen
  ├─ Inicia runtime
  └─ Ejecuta código fuera del handler (global scope)
         │
         ▼ (handler listo)
INVOKE phase
  └─ Lambda invoca tu handler()
         │
         ▼ (respuesta enviada)
FREEZE (entorno en espera)
         │
         ▼ (nueva invocación)
THAW (reutiliza el entorno) ← warm start
         │
         ▼ (timeout de idle ~15 min sin tráfico)
SHUTDOWN
```

**Implicación práctica:** las conexiones a base de datos abiertas en el global scope se reutilizan entre invocaciones del mismo entorno. Una conexión nueva por invocación es un anti-patrón.

---

## Cold Start vs Warm Start

| Aspecto | Cold Start | Warm Start |
|---------|------------|------------|
| Causa | Nuevo entorno (sin pool disponible) | Reutiliza entorno existente |
| Latencia extra | 100ms – 1s (runtime + código) | ~0ms overhead |
| Frecuencia | Primera invocación + tras idle | La mayoría del tráfico |
| Afecta a | Funciones de baja frecuencia | No aplica |

### Qué aumenta el cold start

- **Tamaño del deployment package** — cada MB adicional importa
- **Runtime** — Java y .NET arrancan más lento que Python/Node
- **VPC** — añadir Lambda a VPC ya no añade latencia (ENI precreada desde 2020)
- **Init code pesado** — importar librerías grandes en global scope

### Cómo mitigarlo

| Técnica | Cuándo | Coste extra |
|---------|--------|-------------|
| Provisioned Concurrency | Latencia crítica (<100ms p99) | Sí (por hora) |
| SnapStart (Java) | Funciones Java con cold start > 1s | No |
| Keep-warm pings | No recomendado (no escala) | Mínimo |
| Reducir package size | Siempre | No |

---

## Tipos de invocación

### 1. Sincrónico (RequestResponse)

```
Cliente ──── invoca ──→ Lambda ──── responde ──→ Cliente
            espera              (mismo HTTP request)
```

**Fuentes:** API Gateway, ALB, CloudFront Functions, Lambda@Edge, Cognito triggers, `aws lambda invoke` sin `--invocation-type Event`.

**Comportamiento en error:** el error se devuelve al cliente. Sin retry automático.

### 2. Asíncrono (Event)

```
Fuente ──── pone en cola ──→ [Event Queue] ──→ Lambda
                                               (2 intentos automáticos)
                                                     │
                                        ┌────────────┴──────────────┐
                                   OnSuccess                    OnFailure
                                (Destination)              (Destination o DLQ)
```

**Fuentes:** S3 events, SNS, SES, EventBridge, `aws lambda invoke --invocation-type Event`.

**Comportamiento en error:** retry 2 veces (con espera). Luego → DLQ o Destination OnFailure.

### 3. Event Source Mapping (streaming/polling)

```
[SQS / Kinesis / DynamoDB Streams / MSK]
         │
         ▼ (Lambda hace polling)
    Lambda procesa batch
         │
    ├─ Éxito → confirma mensajes
    └─ Error → retry / bisect-on-error / DLQ
```

**Lambda gestiona el polling** — tú no consumes mensajes explícitamente.

---

## Concurrencia

```
Concurrencia = invocaciones simultáneas activas en un momento dado

Soft limit de cuenta: 1000 invocaciones concurrentes (region)
```

### Tipos

| Tipo | Descripción | Cuándo |
|------|-------------|--------|
| Unreserved | Comparte el pool de 1000 con otras funciones | Default |
| Reserved | Garantiza N para esta función, limita el máximo | Proteger downstream / limitar blast radius |
| Provisioned | Pre-calienta N entornos (elimina cold start) | Latencia P99 crítica |

**Throttling:** cuando se supera el límite → código de error 429 TooManyRequests. En invocaciones síncronas el cliente recibe el error. En asíncronas, Lambda hace retry automáticamente.

---

## Deployment: zip vs container image

| Aspecto | ZIP (.zip) | Container Image |
|---------|------------|-----------------|
| Tamaño máx | 250 MB descomprimido | 10 GB |
| Build | `zip` / SAM / CDK | `docker build` + ECR |
| Cold start | Más rápido | Más lento (caching mejora esto) |
| Consistencia | Runtime fijo por AWS | Tú controlas el runtime |
| Casos | La mayoría | Dependencias grandes, custom runtimes |

---

## Lambda Layers

Una layer es un **ZIP de dependencias o utilidades** que se monta en `/opt/` dentro del execution environment. Se puede compartir entre funciones y cuentas.

```
/opt/
  python/lib/python3.12/site-packages/   ← layer de dependencias Python
  bin/                                    ← layer de binarios (ffmpeg, etc.)
```

**Máximo 5 layers por función.** El tamaño total (función + layers) no puede superar 250 MB descomprimido.

---

## Lambda Destinations vs DLQ

Ambos manejan invocaciones asíncronas fallidas, pero son distintos:

| Aspecto | DLQ (SQS/SNS en función) | Lambda Destinations |
|---------|--------------------------|---------------------|
| Cuándo se activa | Solo en fallo (tras retries) | Éxito Y fallo |
| Payload | Solo el mensaje original | Mensaje + contexto + respuesta |
| Targets posibles | SQS, SNS | SQS, SNS, EventBridge, otra Lambda |
| Configuración | En la función | En el event invoke config |

**Regla:** usa Destinations para workflows modernos. DLQ es legacy pero válido para compatibilidad.

---

## Pricing

```
Precio = (Nº de requests × $0.0000002) + (GB-segundos × $0.0000166667)

Free tier mensual:
  - 1M requests
  - 400,000 GB-segundos

Ejemplo: función de 128 MB que tarda 100ms → 0.0125 GB-s por invocación
  → 100M invocaciones/mes ≈ $16.67 (solo compute)
```

**Provisioned Concurrency:** $0.0000041 por GB-segundo de concurrencia provisionada (independiente de si se invoca).

---

## Anti-patrones comunes

| Anti-patrón | Problema | Alternativa |
|-------------|----------|-------------|
| Lambda que llama Lambda síncrono | Doble cobro de latencia, acoplamiento | SQS entre ellas o Step Functions |
| Abrir conexión DB en handler | Nueva conexión cada invocación | Conexión en global scope + RDS Proxy |
| Monolito Lambda (>10 MB) | Cold start alto, difícil de mantener | Dividir en funciones especializadas |
| Keep-warm con EventBridge cron | No escala con concurrencia | Provisioned Concurrency |
| Secrets hardcoded en env vars | Secretos en CloudTrail/logs | Secrets Manager + caching SDK |

---

## Recursos relacionados

- [sub-labs →](../labs/)
- [terraform →](../terraform/)
- [scenarios →](../scenarios/)
- [Lambda Developer Guide](https://docs.aws.amazon.com/lambda/latest/dg/)
