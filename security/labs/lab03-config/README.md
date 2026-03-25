# Lab 03 — AWS Config

> **Coste estimado:** ~$2-5/mes mientras el recorder está activo | **Región:** eu-west-1

---

## Objetivo

Dominar AWS Config como herramienta de auditoría y compliance: grabación continua del estado de recursos, reglas managed y custom, remediación automática via SSM, y visión agregada multi-cuenta. Contenido relevante para SAA-C03.

---

## Arquitectura

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  AWS Config                                                                  │
│                                                                              │
│  ┌─────────────────┐    ┌──────────────────────────────────────────────┐   │
│  │ Configuration   │    │  Config Rules                                 │   │
│  │ Recorder        │───>│  ┌─────────────┐  ┌──────────────────────┐  │   │
│  │                 │    │  │ Managed     │  │ Custom Lambda        │  │   │
│  │ Graba todos los │    │  │ restricted- │  │ ec2-required-tag-    │  │   │
│  │ recursos →      │    │  │ ssh         │  │ environment          │  │   │
│  │ S3 bucket       │    │  └──────┬──────┘  └──────────┬───────────┘  │   │
│  └─────────────────┘    │         │                    │               │   │
│                          │         ▼                    ▼               │   │
│                          │  NON_COMPLIANT → Automatic Remediation       │   │
│                          │  SSM: AWS-DisablePublicAccessForSecurityGroup │   │
│                          └──────────────────────────────────────────────┘   │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ Config Aggregator (lab05)                                            │   │
│  │ Vista centralizada de compliance (solo lectura)                      │   │
│  │ Para remediar cross-account: EventBridge → Lambda → sts:AssumeRole  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Labs

| Lab | Objetivo | Coste |
|-----|---------|-------|
| [01 — Setup](labs/01-setup/README.md) | Habilitar Config: recorder, delivery channel, IAM role | ~$0.50/h |
| [02 — Rules](labs/02-rules/README.md) | Managed rules + recursos NON_COMPLIANT | ~$0.001/evaluación |
| [03 — Remediation](labs/03-remediation/README.md) | Automatic remediation con SSM Automation | ~$0.00025/step |
| [04 — Custom Rule](labs/04-custom-rule/README.md) | Lambda custom que verifica tags EC2 | ~$0.20 |
| [05 — Aggregator](labs/05-aggregator/README.md) | Vista centralizada + límites del Aggregator | ~$0.003/item |

**Orden recomendado:** 01 → 02 → 03 → 04 → 05 (cada lab tiene prerequisito el anterior)

---

## Mapa conceptual

Ver [concept-map/README.md](concept-map/README.md) para:
- Los tres componentes de Config: Recorder, Rules, Remediation
- Diferencia entre change-triggered vs periodic rules
- Qué puede y qué no puede hacer el Aggregator
- Comparativa: Config vs GuardDuty vs Macie vs Security Hub

---

## Terraform

El directorio [terraform/](terraform/) contiene la configuración base de Config con:
- S3 bucket (delivery channel) con bucket policy correcta
- IAM Role con `AWS_ConfigRole`
- Configuration Recorder + Delivery Channel
- Config Rules (`restricted-ssh`, `s3-bucket-public-read-prohibited`)
- Recursos opcionales para testing: SG con puerto 22 abierto, bucket S3 público

```bash
cd terraform/

# Setup básico (solo Config)
terraform init
terraform apply

# Con recursos que violan las reglas (para lab02)
terraform apply -var="create_open_sg=true" -var="create_public_s3_bucket=true"

# Limpiar todo
terraform destroy
```

---

## Scenarios SAA-C03

Ver [scenarios/README.md](scenarios/README.md) para 4 escenarios de examen:

1. Detectar cambios de configuración (Config vs CloudTrail)
2. Remediación automática de Security Groups
3. Compliance multi-cuenta con Aggregator
4. Custom rule vs Managed rule

---

## Limpieza

Ver [cleanup.md](cleanup.md) para instrucciones completas.

**Lo más importante:** detener el recorder para eliminar el coste recurrente:

```bash
aws configservice stop-configuration-recorder \
  --configuration-recorder-name default \
  --region eu-west-1
```

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Qué graba el historial de configuración? | **AWS Config** — Recorder |
| ¿Cómo detectar SGs con puerto 22 abierto? | Config Rule `restricted-ssh` (managed) |
| ¿Cómo remediar automáticamente? | Config Rule → SSM Automation Document |
| ¿Diferencia SSM vs EventBridge+Lambda? | SSM: nativo en Config, simple. EventBridge: cualquier evento, lógica custom |
| ¿Qué es el Aggregator? | Vista read-only de compliance multi-cuenta |
| ¿Puede el Aggregator remediar? | **NO** — solo lectura |
| ¿Cómo hacer custom rule? | Lambda → `config:PutEvaluations` → `COMPLIANT`/`NON_COMPLIANT` |
