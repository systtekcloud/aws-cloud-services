# Lab 05: AWS Step Functions

Step Functions es el servicio de **orquestación de workflows** de AWS. Define flujos de trabajo como máquinas de estado en ASL (Amazon States Language). Gestiona reintentos, timeouts, estado entre pasos y auditoría completa de cada ejecución.

---

## Sub-labs

| Sub-lab | Contenido | Tiempo |
|---------|-----------|--------|
| [01-orchestration-basics](labs/01-orchestration-basics/) | State machine 3 pasos, ejecutar con CLI, historial visual, Catch + Fail | 45 min |
| [02-error-handling](labs/02-error-handling/) | Retry con JitterStrategy, compensaciones, TimeoutSeconds, HeartbeatSeconds | 40 min |
| [03-distributed-map](labs/03-distributed-map/) | Procesar 20 CSVs en S3 en paralelo, MaxConcurrency, ToleratedFailurePercentage | 40 min |
| [04-saga-pattern](labs/04-saga-pattern/) | Saga con compensaciones — reserva de viaje vuelo+hotel+coche | 50 min |

---

## Conceptos clave

| Concepto | Resumen |
|----------|---------|
| Standard | Exactly-once, hasta 1 año, historial completo. Para workflows críticos |
| Express | At-least-once, hasta 5 min, alta frecuencia. Para microservicios |
| ASL | Amazon States Language — JSON que define los estados del workflow |
| Retry + BackoffRate | Reintentos automáticos con espera exponencial |
| JitterStrategy: FULL | Aleatoriza el tiempo de espera — evita thundering herd |
| Catch | Routing a estado de compensación cuando se agotan los reintentos |
| waitForTaskToken | Pausa el workflow hasta que un sistema externo señaliza |
| Distributed Map | Procesa hasta 10.000 items en paralelo desde S3/array/CSV |
| Saga Pattern | Transacciones distribuidas con compensaciones en orden inverso |

---

## Terraform quickstart

```bash
cd terraform/
terraform init && terraform apply

# Ejecutar el workflow Standard
aws stepfunctions start-execution \
  --state-machine-arn "$(terraform output -raw standard_state_machine_arn)" \
  --input '{"pedido": {"pedido_id": "P001", "cliente_id": "c1", "total": 99.99}}' \
  --region eu-west-1
```

---

## Recursos

- [concept-map/](concept-map/) — Standard vs Express, estados ASL, retry, waitForTaskToken, pricing
- [scenarios/](scenarios/) — Step Functions vs SQS+Lambda, Standard vs Express, Saga vs 2PC, Distributed Map vs EMR
- [terraform/](terraform/) — Standard + Express workflows con Lambda tasks y CloudWatch logging
- [cleanup.md](cleanup.md)
- [Step Functions Developer Guide](https://docs.aws.amazon.com/step-functions/latest/dg/)
