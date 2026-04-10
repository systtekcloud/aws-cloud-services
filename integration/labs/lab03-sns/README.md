# Lab 03: Amazon SNS

Amazon SNS es el servicio de **pub/sub** de AWS. Publica un mensaje en un topic y todos los suscriptores lo reciben simultáneamente. La base del patrón fan-out en arquitecturas event-driven.

---

## Sub-labs

| Sub-lab | Contenido | Tiempo |
|---------|-----------|--------|
| [01-fan-out](labs/01-fan-out/) | Topic → 3 SQS queues, verificar entrega simultánea, envelope SNS | 35 min |
| [02-filtering](labs/02-filtering/) | Filter policies por atributo y por body, routing selectivo | 30 min |

---

## Conceptos clave

| Concepto | Resumen |
|----------|---------|
| Topic | Canal de distribución. Publicadores escriben, subscribers reciben |
| Fan-out | 1 publish → N subscribers reciben simultáneamente |
| SNS + SQS | Patrón recomendado: SNS para fan-out, SQS para durabilidad |
| Filter Policy | Cada subscriber declara qué mensajes quiere por atributos o body |
| Envelope | SNS envuelve el mensaje en un JSON con metadata al entregarlo a SQS |
| FIFO Topic | Fan-out con orden estricto, solo hacia SQS FIFO |

---

## Patrón SNS + SQS

```hcl
# Terraform
resource "aws_sns_topic_subscription" "mi_sub" {
  topic_arn     = aws_sns_topic.mi_topic.arn
  protocol      = "sqs"
  endpoint      = aws_sqs_queue.mi_queue.arn
  filter_policy = jsonencode({ tipo = ["pedido"] })
}
```

---

## Recursos

- [concept-map/](concept-map/)
- [scenarios/](scenarios/)
- [terraform/](terraform/)
- [cleanup.md](cleanup.md)
- [SNS Developer Guide](https://docs.aws.amazon.com/sns/latest/dg/)
