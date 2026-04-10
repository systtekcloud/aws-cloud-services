# Análisis de costes: Async Payment Processing

**Supuesto base:** 1.000.000 pagos/mes (fintech mediana)  
**Región:** eu-west-1 (Irlanda)

---

## Dev

Propósito: pruebas funcionales, 100-1.000 pagos/día, sin HA.

| Servicio | Configuración | Coste/mes |
|----------|--------------|-----------|
| API Gateway REST | 30.000 req/mes × $3.50/M | $0.11 |
| SQS FIFO | 30.000 msg/mes × $0.50/M | $0.02 |
| Lambda (validador) | 30.000 inv × 256MB × 30s | $0.18 |
| Lambda (banco) | 30.000 inv × 256MB × 3s | $0.02 |
| Step Functions | 30.000 exec × 5 transiciones × $0.025/1K | $3.75 |
| DynamoDB | On-demand, 30K reads + 30K writes | $0.04 |
| SNS | 30.000 notificaciones | $0.03 |
| CloudWatch Logs | ~1GB logs | $0.50 |
| KMS | 30.000 requests | $0.03 |
| **Total Dev** | | **~$4.68/mes** |

---

## Prod

Propósito: 1M pagos/mes con HA, auditoría, auto-scaling.

| Servicio | Configuración | Coste/mes |
|----------|--------------|-----------|
| API Gateway REST | 1M req/mes × $3.50/M | $3.50 |
| SQS FIFO | 1M msg/mes × $0.50/M | $0.50 |
| Lambda (validador) | 1M inv × 256MB × 30s | $6.00 |
| Lambda (banco) | 1M inv × 256MB × 3s | $0.60 |
| Step Functions Standard | 1M exec × 5 transiciones × $0.025/1K | $125.00 |
| DynamoDB Provisioned | 25 RCU + 10 WCU baseline + auto-scaling | $18.00 |
| DynamoDB PITR | ~10GB datos × $0.20/GB | $2.00 |
| SNS | 1M notificaciones | $1.00 |
| CloudWatch Logs | ~30GB logs | $15.00 |
| CloudWatch Alarms | 5 alarmas × $0.10 | $0.50 |
| KMS (CMK) | $1/mes + 1M requests × $0.03/10K | $4.00 |
| **Total Prod** | | **~$176/mes** |

---

## Desglose Step Functions (mayor coste)

Step Functions Standard cobra por transición de estado:

```
1M pagos/mes × 5 transiciones/pago = 5M transiciones/mes
5M transiciones × $0.025/1000 = $125/mes
```

Las 5 transiciones por pago son:
1. ValidarConBanco → (resultado banco)
2. RegistrarTransaccion → (DynamoDB PutItem)
3. NotificarCliente → (SNS Publish)
4. (Si rechazo) NotificarRechazo → END
5. Estado terminal END

**¿Merece la pena?** Para fintech con auditoría legal obligatoria: SÍ.
- Alternativa con EventBridge coreografía: ~$50/mes pero sin visibilidad del flujo
- El ahorro de $75/mes no compensa el riesgo regulatorio de no tener auditoría

---

## Comparativa vs alternativas

| Configuración | Coste 1M pagos/mes | SLA facilidad | Auditoría |
|--------------|-------------------|---------------|-----------|
| **A: SQS FIFO + SFN** (elegida) | ~$176 | Alta | Nativa |
| B: ECS + RDS Aurora | ~$280-320 | Media | Manual |
| C: EventBridge coreografía | ~$50 | Media | Manual |

**B cuesta más porque:**
- ECS Fargate: ~$50/mes mínimo (2 tasks × 0.25 vCPU × 0.5GB)
- RDS Aurora Serverless v2: mínimo $0.12/ACU-hora × 730h = $87/mes
- RDS Proxy: ~$30/mes por instancia

**C cuesta menos porque:**
- Sin Step Functions ($125 ahorro)
- EventBridge: $1/M eventos = $1/mes
- Pero: hay que construir auditoría manualmente (+desarrollo) y debugging es complejo

---

## Optimizaciones de coste

### Opción 1: Step Functions Express para volúmenes extremos

Si el negocio crece a 100M pagos/mes:

```
Standard: 100M × 5 × $0.025/1K = $12,500/mes  ← inviable
Express:  100M × $1/M = $100/mes               ← viable
```

**Pero Express no tiene historial de auditoría.** Solución híbrida:
- Express Workflow para el flujo principal
- Cada estado escribe en DynamoDB (audit trail manual)
- CloudWatch Logs con 90 días retención para auditoría operacional

### Opción 2: Reducir Lambda timeout

Si el banco responde en <5s, timeout de 30s → 10s:
- Ahorro: ~66% del coste de Lambda
- Impacto: `visibility_timeout` de SQS también puede bajar

### Opción 3: DynamoDB on-demand en prod (si tráfico irregular)

Si los pagos son muy estacionales (ej: Black Friday × 10):
- On-demand auto-escala sin límite
- Coste: $1.25/M writes + $0.25/M reads vs provisioned fijo
- Break-even: ~20M writes/mes → usar provisioned si el tráfico es estable

---

## Estimación TCO 3 años (1M pagos/mes estable)

```
Dev:  $4.68 × 36 meses  = $168
Prod: $176  × 36 meses  = $6,336
Desarrollo inicial       = ~80h × $100/h = $8,000
Mantenimiento/año        = ~20h × $100/h = $6,000
                                          ────────
TCO 3 años                               ~$22,504
```

Para 1M pagos/mes, el coste por transacción es:
**$176 ÷ 1.000.000 = $0.000176/pago** — prácticamente despreciable.
