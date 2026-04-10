# Por qué ECS y no Lambda para OCR

## Comparativa de restricciones

| Restricción | Lambda | ECS Fargate |
|------------|--------|-------------|
| Timeout | 15 min máximo | Sin límite |
| Memoria | 128MB – 10GB | 512MB – 120GB |
| vCPU | Proporcional a RAM | 0.25 – 16 vCPU |
| Tamaño imagen | 50MB (zip) / 10GB (container) | Sin límite práctico |
| Dependencias del sistema | Limitadas (Lambda layers) | Cualquier cosa en Docker |
| Disco temporal | 512MB – 10GB (/tmp) | EFS mount o efímero |
| Arranque en frío | 100ms – 10s | 30s – 2min |

## El caso concreto: Tesseract OCR

```dockerfile
# Imagen Docker para OCR (no funciona como Lambda layer)
FROM python:3.12-slim

# Tesseract requiere librerías de sistema
RUN apt-get update && apt-get install -y \
    tesseract-ocr \
    tesseract-ocr-spa \  # idioma español
    libopencv-dev \
    poppler-utils \      # para pdftoppm
    && rm -rf /var/lib/apt/lists/*

# Modelo de lenguaje de Tesseract: 50MB adicionales
# OpenCV: 200MB
# Total imagen: ~800MB → imposible en Lambda zip, viable en ECR

RUN pip install pytesseract opencv-python-headless pdf2image boto3
COPY processor.py .
CMD ["python", "processor.py"]
```

**Lambda Alternative:** AWS Textract (servicio gestionado de OCR).
- Pros: sin gestionar contenedor, pay-per-use
- Contras: $1.50/1K páginas (Textract) vs $0.04/hora (Fargate t-shirt) — si procesas 10K páginas/día, Fargate es 10× más barato

## Cuándo usar Lambda para pipelines de documentos

Lambda es adecuado si:
- PDFs de <10 páginas y <50MB (caben en el timeout)
- Usas Textract en vez de Tesseract propio
- No hay dependencias de sistema (solo Python puro)
- El volumen es bajo (<100 docs/día)

ECS es necesario cuando:
- Documentos grandes o procesamiento largo (OCR, NLP pesado)
- Dependencias de sistema (Tesseract, LibreOffice, ffmpeg, etc.)
- Se quiere usar modelos ML/AI propios (no servicios AWS)
- El coste de servicios gestionados (Textract, Comprehend) es prohibitivo

## El rol de Step Functions con ECS Tasks

Step Functions puede lanzar ECS Tasks de dos maneras:

### Opción A: sync (Task.sync — espera hasta completar)

```json
{
  "Type": "Task",
  "Resource": "arn:aws:states:::ecs:runTask.sync",
  "Parameters": {
    "LaunchType": "FARGATE",
    "TaskDefinition": "ocr-processor",
    "Overrides": {
      "ContainerOverrides": [{
        "Name": "processor",
        "Environment": [
          {"Name": "DOC_S3_KEY", "Value.$": "$.s3_key"},
          {"Name": "TASK_TOKEN", "Value.$": "$$.Task.Token"}
        ]
      }]
    }
  }
}
```

Pros: Step Functions sabe cuándo termina el task automáticamente.
Contras: la ejecución de Step Functions permanece "abierta" (coste por tiempo en Standard).

### Opción B: waitForTaskToken (el ECS Task hace callback)

```json
{
  "Type": "Task",
  "Resource": "arn:aws:states:::ecs:runTask.waitForTaskToken",
  "Parameters": {
    "LaunchType": "FARGATE",
    "TaskDefinition": "ocr-processor",
    "Overrides": {
      "ContainerOverrides": [{
        "Name": "processor",
        "Environment": [
          {"Name": "DOC_S3_KEY", "Value.$": "$.s3_key"},
          {"Name": "TASK_TOKEN", "Value.$": "$$.Task.Token"}
        ]
      }]
    }
  },
  "HeartbeatSeconds": 3600
}
```

El contenedor llama a `SendTaskSuccess` o `SendTaskFailure` cuando termina. Más flexible pero requiere que el código del contenedor lo implemente.

**Este laboratorio usa `waitForTaskToken`** porque permite que el container envíe resultados parciales (heartbeats) durante el procesamiento largo.
