# ECS + EventBridge + Step Functions: Pipeline de procesamiento de documentos

**Tipo:** Service-Combination  
**Combinación no obvia:** ECS Fargate + EventBridge + Step Functions

**Caso de uso:** Pipeline de OCR/procesamiento de PDFs. Los documentos llegan, se procesan (OCR, extracción de datos, validación, almacenamiento), y el resultado se entrega.

---

## ¿Por qué esta combinación no es obvia?

Lambda parece la opción natural para pipelines de documentos. Pero hay límites concretos:

| Restricción Lambda | Impacto en OCR/PDF |
|-------------------|-------------------|
| Timeout máximo: 15 min | OCR de PDF de 100 páginas puede tardar 20+ min |
| Tamaño de payload: 6MB | PDFs de alta resolución son 50-200MB |
| Memoria máxima: 10GB | Tesseract + OpenCV necesitan 4-8GB para documentos grandes |
| /tmp: 10GB | Suficiente, pero complejo de gestionar en batch |

**ECS Fargate** elimina estos límites: runs containerizados con hasta 120GB RAM, 16 vCPU, sin timeout.

**Pero ECS no tiene orquestación ni manejo de errores.** Aquí entran Step Functions y EventBridge.

---

## Arquitectura

```
                    Ingesta
S3 (documentos nuevos)
  │ s3:ObjectCreated event
  ▼
EventBridge (default bus)
  │ Rule: source=aws.s3, prefix=/incoming/
  ▼
Step Functions (orquestador del pipeline)
  │
  ├─ ValidarDocumento (Lambda: tipo, tamaño, formato)
  │
  ├─ ProcessarOCR (ECS Task — Fargate)
  │   │ Imagen Docker con Tesseract + OpenCV
  │   └─ Output: texto extraído → S3
  │
  ├─ ExtraerDatos (ECS Task — Fargate)
  │   │ NLP/reglas para extraer campos (fechas, importes, nombres)
  │   └─ Output: JSON estructurado → DynamoDB
  │
  ├─ ValidarExtraccion (Lambda: campos obligatorios, rangos)
  │   ├─ OK → RegistrarCompletado
  │   └─ Baja confianza → RevisionManual
  │
  ├─ RegistrarCompletado (DynamoDB + SNS notificación)
  │
  └─ RevisionManual (SQS → cola para operadores)
              │
              ▼ (operador aprueba en dashboard)
         Step Functions callback (waitForTaskToken)
              ▼
         RegistrarCompletado

CloudWatch: métricas por etapa, P95 de tiempo de procesamiento
```

---

## Por qué cada servicio

**EventBridge (no Lambda trigger en S3):**
- S3 Event Notification → EventBridge permite múltiples targets sin código adicional
- El mismo evento puede ir a Step Functions + CloudWatch + Slack (3 targets, 0 código)
- Filtros declarativos: solo PDFs > 100KB en el prefix `/incoming/documentos-fiscales/`

**Step Functions (no Lambda chain):**
- ECS Tasks pueden tardar 20-60 minutos → Step Functions los orquesta con `waitForTaskToken`
- Si falla el OCR: retry declarativo con backoff, sin código adicional
- Visibilidad: el dashboard muestra exactamente en qué estado está cada documento

**ECS Fargate (no Lambda para OCR):**
- Timeout de 20+ minutos → Lambda no puede
- Imagen Docker con Tesseract (dependencia de sistema, no solo Python)
- Escalado automático: si llegan 100 PDFs simultáneos, 100 Fargate tasks en paralelo

---

## Módulos Terraform

| Módulo | Recursos | Descripción |
|--------|----------|-------------|
| [modules/ingestion/](modules/ingestion/) | S3 + EventBridge rule | Trigger del pipeline |
| [modules/pipeline/](modules/pipeline/) | Step Functions + ECS + Lambda | Orquestación |
| [modules/infrastructure/](modules/infrastructure/) | VPC + ECS Cluster + ECR + DynamoDB | Infraestructura base |

---

## Recursos relacionados

- [design/why-ecs-not-lambda.md](design/why-ecs-not-lambda.md) — Comparativa detallada
- [scenarios/](scenarios/) — Batch processing, documentos corruptos, revisión manual
