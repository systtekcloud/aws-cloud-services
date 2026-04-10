# Lab 01: AWS Lambda

AWS Lambda es el servicio de compute sin servidor de AWS. Ejecutas código en respuesta a eventos sin gestionar servidores. Pagas solo por el tiempo de ejecución real.

---

## Arquitectura del lab

```
                    ┌─────────────────────────────────────┐
                    │           lab01-lambda               │
                    │                                      │
  S3 Event ─────────┤                                      │
  SNS/EventBridge ──┤──→ [SQS Trigger Queue] ──→ Lambda  ──┤──→ [Success Queue]
  API Gateway ──────┤    (Event Source Mapping)    │        │
  CLI (invoke) ─────┤                              │        │──→ [Failure Queue]
                    │                          DLQ │        │
                    │                              ▼        │
                    │                         [Trigger DLQ] │
                    └─────────────────────────────────────-─┘

  Lambda Layer (dependencias Python) ──→ adjunto a la función
```

---

## Sub-labs

| Sub-lab | Contenido | Tiempo |
|---------|-----------|--------|
| [01-fundamentos](labs/01-fundamentos/) | Crear función, invocar sync/async, S3 trigger, medir cold start | 45 min |
| [02-concurrency-scaling](labs/02-concurrency-scaling/) | Reserved/Provisioned concurrency, SnapStart, Power Tuning | 60 min |
| [03-layers-extensions](labs/03-layers-extensions/) | Lambda Layers, Extensions, Custom Runtimes | 45 min |
| [04-lambda-destinations](labs/04-lambda-destinations/) | Destinations OnSuccess/OnFailure, DLQ, ESM con bisect-on-error | 45 min |

---

## Terraform quickstart

```bash
# Prerrequisito: crear el ZIP del código y el layer
mkdir -p terraform/src/
cat > terraform/src/handler.py << 'EOF'
import json
def handler(event, context):
    return {'statusCode': 200, 'body': json.dumps({'received': event})}
EOF

# Opcionalmente: crear layer ZIP
# mkdir -p /tmp/layer/python && pip install requests -t /tmp/layer/python/
# cd /tmp/layer && zip -r layer.zip python/ && cp layer.zip terraform/

cd terraform/
terraform init
terraform plan
terraform apply
```

---

## Conceptos clave

| Concepto | Resumen |
|----------|---------|
| Execution Environment | MicroVM que ejecuta tu función. Se reutiliza (warm) o se crea nuevo (cold start) |
| Cold Start | Latencia extra en el primer invoke tras idle. Mitigar con Provisioned Concurrency |
| Reserved Concurrency | Limita Y garantiza slots para esta función |
| Provisioned Concurrency | Pre-calienta entornos — elimina cold start. Tiene coste por hora |
| Lambda Layer | ZIP de dependencias compartidas. Montado en `/opt/`. Máximo 5 layers |
| Destinations | OnSuccess/OnFailure para invocaciones async. Más info que DLQ |
| ESM | Event Source Mapping — Lambda hace polling de SQS/Kinesis/DDB Streams |

---

## Decisión rápida: ¿Lambda o no?

```
¿Tu proceso dura < 15 min?         → Sí: Lambda candidato
¿Necesita < 10 GB RAM?             → Sí: Lambda candidato
¿El tráfico es irregular/bursty?   → Sí: Lambda ventaja en coste
¿Necesitas cold start < 100ms p99? → Provisioned Concurrency
¿Todo lo anterior es Sí?           → Usa Lambda
```

---

## Recursos

- [concept-map/](concept-map/) — Modelo de ejecución completo
- [scenarios/](scenarios/) — Lambda vs ECS, cold start, idempotency, coste
- [terraform/](terraform/) — IaC completo
- [cleanup.md](cleanup.md) — Eliminación de recursos
- [AWS Lambda docs](https://docs.aws.amazon.com/lambda/latest/dg/)
- [Lambda Powertools](https://docs.powertools.aws.dev/lambda/python/)
