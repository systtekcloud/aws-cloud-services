# Lab 08 — Amazon Detective

> **Coste:** GRATIS durante 30 días de free trial | **Región:** eu-west-1
> **Prerrequisito OBLIGATORIO:** lab04-guardduty activo con findings
> **NOTA:** Planificar con 24-48h de antelación (maduración del behavior graph)

---

## Objetivo

Dominar Amazon Detective como herramienta de investigación forense: behavior graph, correlación automática de CloudTrail + VPC Flow Logs + GuardDuty, y el flujo de investigación desde un GuardDuty finding. Contenido frecuente en SAA-C03.

---

## La distinción más importante del lab

```
Detective NO detecta amenazas    →   GuardDuty detecta
Detective NO agrega findings     →   Security Hub agrega
Detective INVESTIGA incidentes   →   correlación automática en minutos
                                     (vs CloudTrail manual = horas)
```

---

## Arquitectura

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Amazon Detective (investigación forense)                                  │
│                                                                            │
│  Fuentes automáticas:              Behavior Graph:                         │
│  ┌───────────────────┐             ┌──────────────────────────────────┐   │
│  │ AWS CloudTrail    │──┐          │  IAM User ── AssumeRole ── Role   │  │
│  │ VPC Flow Logs     │  ├──────►  │     │                    │         │  │
│  │ GuardDuty findings│──┘          │  S3 GetObject x47    EC2 SSH      │  │
│  └───────────────────┘             │  [ANÓMALO: 3σ]      [IP nueva]   │  │
│                                    └──────────────────────────────────┘   │
│                                                                            │
│  Retención: 1 año                  Maduración: 24-48h                     │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Labs

| Lab | Objetivo | Tiempo |
|-----|---------|--------|
| [01 — Setup](labs/01-setup/README.md) | Habilitar Detective + generar sample findings | 15 min |
| [02 — Investigation](labs/02-investigation/README.md) | Investigar finding de GuardDuty en el grafo | 30 min (+ 24-48h espera) |

**Orden:** 01 → esperar 24-48h → 02

---

## Mapa conceptual

Ver [concept-map/README.md](concept-map/README.md) para:
- Detective vs CloudTrail — diferencia crítica para SAA-C03
- Detective vs Security Hub — cuándo usar cada uno
- Behavior graph y cómo funciona la correlación automática
- Flujo de investigación: GuardDuty finding → Detective → conclusión
- Analogía distributed tracing

---

## Terraform

El directorio [terraform/](terraform/) contiene:

```bash
cd terraform/

# Crear behavior graph
terraform init
terraform apply

# Limpiar
terraform destroy
```

> Prerrequisito: GuardDuty debe estar habilitado antes de `terraform apply`.

---

## Scenarios SAA-C03

Ver [scenarios/README.md](scenarios/README.md) para 3 escenarios de examen:

1. Detective vs CloudTrail para investigación de incidentes
2. Orden correcto de respuesta a incidente (snapshot → aislar → investigar → notificar)
3. Detective vs Security Hub — cuándo usar cada uno

---

## Limpieza

Ver [cleanup.md](cleanup.md) para instrucciones completas, incluyendo el **teardown ordenado de todos los labs de security** (Detective → Security Hub → Inspector → Macie → GuardDuty).

```bash
GRAPH_ARN=$(aws detective list-graphs --region eu-west-1 --query 'GraphList[0].Arn' --output text)
aws detective delete-graph --graph-arn "$GRAPH_ARN" --region eu-west-1
```

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Detective detecta amenazas? | **No** — GuardDuty detecta, Detective investiga |
| ¿Prerrequisito para Detective? | GuardDuty activo con findings |
| ¿Qué es el behavior graph? | Modelo del comportamiento normal de entidades (usuarios, roles, instancias) |
| ¿Detective vs CloudTrail? | Detective = correlación automática (minutos). CloudTrail = logs en bruto (horas) |
| ¿Detective vs Security Hub? | Detective = investigar UN incidente. Security Hub = postura GLOBAL |
| Orden de respuesta a incidente | Snapshot → Aislar → Investigar (Detective) → Notificar |
| ¿Cuánto tiempo retiene datos? | 1 año |
| ¿Necesita configurar fuentes de datos? | **No** — ingiere CloudTrail + VPC Flow Logs + GuardDuty automáticamente |
