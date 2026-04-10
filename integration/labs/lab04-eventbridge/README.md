# Lab 04: Amazon EventBridge

EventBridge es el **event bus serverless** de AWS. Enruta eventos de servicios AWS, aplicaciones propias y SaaS de terceros a múltiples targets mediante reglas declarativas. Es el núcleo de las arquitecturas event-driven modernas.

---

## Sub-labs

| Sub-lab | Contenido | Tiempo |
|---------|-----------|--------|
| [01-rules-patterns](labs/01-rules-patterns/) | Custom bus, event patterns complejos, input transformers, test-event-pattern | 40 min |
| [02-event-bus-cross-account](labs/02-event-bus-cross-account/) | Bus central multi-cuenta, resource policy, cross-bus routing con IAM role | 30 min |

---

## Conceptos clave

| Concepto | Resumen |
|----------|---------|
| Default Bus | Recibe eventos AWS automáticamente. Para automatización de ops |
| Custom Bus | Para eventos de tu aplicación. Aislamiento + cross-account |
| Event Pattern | JSON que define qué eventos captura una regla. Soporta `prefix`, `numeric`, `anything-but`, `exists` |
| Input Transformer | Transforma el evento antes de enviarlo al target. Sin Lambda intermedia |
| EventBridge Pipes | Source → Filter → Enrich → Target. Sin Lambda glue |
| Schema Registry | Descubre y valida esquemas de eventos automáticamente |
| Archive + Replay | Almacena eventos para reprocesarlos en caso de fallo o debugging |

---

## Terraform quickstart

```bash
cd terraform/
terraform init && terraform apply

# Publicar evento de prueba
aws events put-events --entries "[{
  \"Source\": \"com.miempresa.pedidos\",
  \"DetailType\": \"PedidoCreado\",
  \"Detail\": \"{\\\"pedido_id\\\": \\\"P001\\\", \\\"total\\\": 800, \\\"tipo\\\": \\\"international\\\", \\\"pais_destino\\\": \\\"FR\\\"}\",
  \"EventBusName\": \"$(terraform output -raw event_bus_name)\"
}]" --region eu-west-1
```

---

## Recursos

- [concept-map/](concept-map/) — Tipos de bus, anatomy, rules, targets, Pipes, pricing
- [scenarios/](scenarios/) — Default vs custom bus, Scheduler, Archive/Replay, Pipes vs Lambda
- [terraform/](terraform/)
- [cleanup.md](cleanup.md)
- [EventBridge User Guide](https://docs.aws.amazon.com/eventbridge/latest/userguide/)
