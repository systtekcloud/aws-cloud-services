# Módulo de Arquitecturas AWS

Arquitecturas end-to-end que combinan múltiples servicios AWS para resolver problemas reales. Cada arquitectura incluye el problem statement, opciones consideradas, tradeoffs, Terraform/Terragrunt para dev y prod, y análisis de coste.

---

## ¿Qué diferencia este módulo de los labs individuales?

Los labs de `integration/` y `eks/` enseñan los servicios en detalle. Este módulo muestra **cómo se combinan** para resolver problemas que las empresas tienen en producción.

Tres enfoques complementarios:

```
problem-first/    → Empiezas con el problema de negocio
                    Ejemplo: "necesito procesar pagos con exactly-once"
                    → Descubres qué servicios resuelven el problema

pattern-first/    → Empiezas con el patrón de arquitectura
                    Ejemplo: "quiero implementar CQRS"
                    → Aprendes cuándo y cómo aplica el patrón

service-combination/ → Empiezas con servicios que parecen no obvios juntos
                    Ejemplo: "¿cuándo usar ECS + EventBridge + Step Functions?"
                    → Aprendes las sinergias entre servicios
```

---

## Arquitecturas

### Problem-First

| # | Problema | Servicios | Prereqs |
|---|----------|-----------|---------|
| [01-async-payment-processing](problem-first/01-async-payment-processing/) | Pagos con exactly-once, auditoría, retry, notificación <5s | API GW → SQS FIFO → Lambda → Step Functions → DynamoDB → SNS | lab02-sqs, lab05-sfn |
| [02-iot-data-pipeline](problem-first/02-iot-data-pipeline/) | 10K sensores IoT, alertas <10s, histórico 2 años, <$500/mes | IoT Core → Kinesis → Lambda → Firehose → S3 → Athena | lab01-lambda, lab02-sqs |

### Pattern-First

| # | Patrón | Servicios | Prereqs |
|---|--------|-----------|---------|
| [01-saga-pattern](pattern-first/01-saga-pattern/) | Saga orquestada para transacciones distribuidas entre microservicios | API GW → Step Functions → ECS Tasks (via SQS) → DynamoDB → SNS | lab05-sfn sub-lab 04 |
| [02-cqrs](pattern-first/02-cqrs/) | CQRS: writes a DynamoDB, reads desde múltiples read stores optimizados | API GW → Lambda → DynamoDB Streams → Lambda → OpenSearch + ElastiCache | lab01-lambda |

### Service-Combination

| # | Combinación | Caso de uso | Prereqs |
|---|-------------|-------------|---------|
| [01-ecs-eventbridge-stepfunctions](service-combination/01-ecs-eventbridge-stepfunctions/) | ECS Fargate + EventBridge + Step Functions | Pipeline de procesamiento de documentos PDF/OCR | lab04-eventbridge, lab05-sfn |
| [02-eks-microservices](service-combination/02-eks-microservices/) | EKS + API GW + Cognito + X-Ray + ArgoCD | Plataforma SaaS B2B con microservicios | eks/lab01-06 |

---

## Cómo leer cada arquitectura

```
1. README.md           → Problem statement + diagrama + decisión de diseño
2. design/
   ├── architecture.md → Diagrama detallado + flujo de datos + decisiones técnicas
   └── options/        → Opciones consideradas y por qué se eligió esta
3. modules/            → Terraform por componente lógico
4. dev/terragrunt.hcl  → Config dev (mínimo coste, sin redundancia)
5. prod/terragrunt.hcl → Config prod (HA, alertas, auto-scaling)
6. scenarios/          → Variantes, extensiones, anti-patrones
7. cost-analysis.md    → Estimación de coste dev vs prod
```

---

## Prerrequisitos recomendados

Antes de este módulo, conviene haber completado:
- `integration/labs/lab01-06` — Lambda, SQS, SNS, EventBridge, Step Functions, API GW
- `networking/labs/lab01-02` — VPC, subnets, security groups
- `security/labs/lab01-04` — IAM, KMS, Secrets Manager, GuardDuty
