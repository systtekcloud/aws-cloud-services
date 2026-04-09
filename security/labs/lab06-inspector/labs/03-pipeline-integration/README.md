# Lab 06.03 — Inspector + Pipeline CI/CD (EventBridge)

> **Coste:** Lambda ~$0.00 (free tier) | **Prerrequisito:** lab 06.02 completado con findings

---

## Objetivo

Crear un flujo completo DevSecOps: Inspector finding severity=CRITICAL → EventBridge Rule → Lambda (simula bloquear pipeline) + SNS (notifica al equipo).

---

## Arquitectura

```
ECR push
   │
   ▼
Inspector Enhanced Scanning
   │ finding: severity=CRITICAL, type=AWS_ECR_CONTAINER_IMAGE
   ▼
EventBridge Rule
   ├──► Lambda: simula bloquear pipeline (API call a CI/CD)
   └──► SNS: notifica al equipo con detalle del CVE
```

---

## Paso 1 — Crear SNS Topic para notificaciones

```bash
export AWS_REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Crear SNS topic
SNS_ARN=$(aws sns create-topic \
  --name lab06-inspector-alerts \
  --region "$AWS_REGION" \
  --query 'TopicArn' --output text)

echo "SNS Topic: $SNS_ARN"

# Suscribir tu email (reemplaza con tu email)
# aws sns subscribe \
#   --topic-arn "$SNS_ARN" \
#   --protocol email \
#   --notification-endpoint "tu-email@ejemplo.com" \
#   --region "$AWS_REGION"
```

---

## Paso 2 — Crear Lambda de remediación

```bash
# Crear el código de la Lambda
mkdir -p /tmp/lab06-lambda
cat > /tmp/lab06-lambda/index.py <<'PYTHON'
import json
import boto3
import os
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def handler(event, context):
    """
    Recibe un Inspector finding via EventBridge.
    Simula bloquear el pipeline CI/CD notificando con el detalle del CVE.
    En producción llamaría a la API de GitHub Actions, GitLab CI, etc.
    """
    logger.info("Inspector finding recibido: %s", json.dumps(event))

    detail = event.get("detail", {})
    severity = detail.get("severity", "UNKNOWN")
    finding_type = detail.get("type", "UNKNOWN")

    # Extraer información del CVE
    pkg_vuln = detail.get("packageVulnerabilityDetails", {})
    cve_id = pkg_vuln.get("vulnerabilityId", "UNKNOWN")
    vulnerable_packages = pkg_vuln.get("vulnerablePackages", [])

    # Extraer recurso afectado
    resources = detail.get("resources", [{}])
    resource_id = resources[0].get("id", "UNKNOWN") if resources else "UNKNOWN"
    resource_type = resources[0].get("type", "UNKNOWN") if resources else "UNKNOWN"

    message = {
        "alert_type": "INSPECTOR_CRITICAL_FINDING",
        "action": "PIPELINE_BLOCKED",
        "severity": severity,
        "cve_id": cve_id,
        "finding_type": finding_type,
        "resource_id": resource_id,
        "resource_type": resource_type,
        "vulnerable_packages": [
            {
                "name": pkg.get("name"),
                "version": pkg.get("version"),
                "fix_in": pkg.get("fixedInVersion", "no-fix-available")
            }
            for pkg in vulnerable_packages
        ],
        "action_taken": "Pipeline bloqueado (simulado). En producción: GitHub Actions API call.",
        "remediation": f"Actualizar {cve_id} en los paquetes afectados"
    }

    logger.info("Acción: %s", json.dumps(message))

    # En producción: llamar a la API de CI/CD para bloquear el pipeline
    # github_token = os.environ['GITHUB_TOKEN']
    # requests.post(f"https://api.github.com/repos/{owner}/{repo}/actions/runs/{run_id}/cancel", ...)

    return {
        "statusCode": 200,
        "body": json.dumps(message)
    }
PYTHON

# Comprimir
cd /tmp/lab06-lambda && zip -r lambda.zip index.py
echo "Lambda código comprimido"
```

```bash
# Crear IAM Role para Lambda
aws iam create-role \
  --role-name lab06-lambda-inspector-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' 2>/dev/null || echo "Role ya existe"

aws iam attach-role-policy \
  --role-name lab06-lambda-inspector-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

sleep 5  # IAM propagation

# Crear Lambda
LAMBDA_ARN=$(aws lambda create-function \
  --function-name lab06-inspector-pipeline-blocker \
  --runtime python3.12 \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/lab06-lambda-inspector-role" \
  --handler index.handler \
  --zip-file fileb:///tmp/lab06-lambda/lambda.zip \
  --timeout 30 \
  --region "$AWS_REGION" \
  --query 'FunctionArn' --output text 2>/dev/null || \
  aws lambda update-function-code \
    --function-name lab06-inspector-pipeline-blocker \
    --zip-file fileb:///tmp/lab06-lambda/lambda.zip \
    --region "$AWS_REGION" \
    --query 'FunctionArn' --output text)

echo "Lambda ARN: $LAMBDA_ARN"
```

---

## Paso 3 — Crear EventBridge Rule

```bash
# Crear EventBridge Rule: Inspector finding CRITICAL en ECR
RULE_ARN=$(aws events put-rule \
  --name lab06-inspector-critical-ecr \
  --description "Inspector CRITICAL findings en ECR → bloquear pipeline" \
  --event-pattern '{
    "source": ["aws.inspector2"],
    "detail-type": ["Inspector2 Finding"],
    "detail": {
      "severity": ["CRITICAL"],
      "resources": {
        "type": ["AWS_ECR_CONTAINER_IMAGE"]
      }
    }
  }' \
  --state ENABLED \
  --region "$AWS_REGION" \
  --query 'RuleArn' --output text)

echo "EventBridge Rule ARN: $RULE_ARN"
```

```bash
# Dar permiso a EventBridge para invocar Lambda
aws lambda add-permission \
  --function-name lab06-inspector-pipeline-blocker \
  --statement-id lab06-eventbridge-inspector \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "$RULE_ARN" \
  --region "$AWS_REGION" 2>/dev/null || echo "Permiso ya existe"

# Obtener ARNs
SNS_ARN=$(aws sns list-topics \
  --region "$AWS_REGION" \
  --query 'Topics[?contains(TopicArn, `lab06-inspector-alerts`)].TopicArn' \
  --output text)

LAMBDA_ARN=$(aws lambda get-function \
  --function-name lab06-inspector-pipeline-blocker \
  --region "$AWS_REGION" \
  --query 'Configuration.FunctionArn' --output text)

# Añadir targets: Lambda + SNS
aws events put-targets \
  --rule lab06-inspector-critical-ecr \
  --targets "[
    {
      \"Id\": \"lambda-pipeline-blocker\",
      \"Arn\": \"${LAMBDA_ARN}\"
    },
    {
      \"Id\": \"sns-team-notification\",
      \"Arn\": \"${SNS_ARN}\"
    }
  ]" \
  --region "$AWS_REGION"

# Dar permiso a EventBridge para publicar en SNS
aws sns set-topic-attributes \
  --topic-arn "$SNS_ARN" \
  --attribute-name Policy \
  --attribute-value "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": {\"Service\": \"events.amazonaws.com\"},
      \"Action\": \"sns:Publish\",
      \"Resource\": \"${SNS_ARN}\"
    }]
  }" \
  --region "$AWS_REGION"

echo "EventBridge targets configurados: Lambda + SNS"
```

---

## Paso 4 — Probar el flujo completo

```bash
# Re-hacer push de la imagen vulnerable para generar un finding nuevo
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/lab06-inspector-demo"

aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin \
  "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Push con nuevo tag para forzar re-escaneo
docker tag lab06-inspector-demo:vulnerable "${ECR_URI}:test-pipeline-$(date +%s)"
docker push "${ECR_URI}:test-pipeline-$(date +%s)"

echo "Imagen subida. Inspector escaneará en 1-5 min."
echo "Si hay findings CRITICAL → EventBridge → Lambda + SNS en segundos."
```

```bash
# Verificar que Lambda fue invocada (ver CloudWatch Logs)
sleep 120  # Esperar el escaneo y la invocación

LOG_GROUP="/aws/lambda/lab06-inspector-pipeline-blocker"
aws logs describe-log-streams \
  --log-group-name "$LOG_GROUP" \
  --order-by LastEventTime \
  --descending \
  --region "$AWS_REGION" \
  --query 'logStreams[0].logStreamName' \
  --output text 2>/dev/null | xargs -I {} aws logs get-log-events \
  --log-group-name "$LOG_GROUP" \
  --log-stream-name {} \
  --region "$AWS_REGION" \
  --query 'events[].message' \
  --output text 2>/dev/null || echo "Lambda aún no invocada (esperar más tiempo o revisar que hay findings CRITICAL)"
```

---

## Por qué Inspector no puede invocar SNS directamente

```
Inspector genera un finding
       │
       ▼
¿Puede Inspector → SNS directamente?    NO

Inspector es un servicio de DETECCIÓN, no de AUTOMATIZACIÓN.
Sus responsabilidades son:
  ✓ Escanear recursos
  ✓ Generar findings
  ✓ Publicar eventos en EventBridge

Sus responsabilidades NO son:
  ✗ Enviar notificaciones
  ✗ Invocar funciones
  ✗ Hacer llamadas API

Para automatizar respuestas a findings de Inspector:
  Inspector → EventBridge (pub/sub) → Lambda/SNS/SQS/Step Functions

Este patrón (servicio de seguridad → EventBridge → acción) es consistente en toda AWS:
  GuardDuty → EventBridge → Lambda (aislar EC2)
  Config Rule → EventBridge → Lambda (remediar)
  Inspector → EventBridge → Lambda (bloquear pipeline)
  Macie → EventBridge → Lambda (cifrar bucket)
```

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Inspector puede invocar SNS directamente? | **No** — necesita EventBridge como intermediario |
| ¿Cómo bloquear un pipeline en respuesta a un CVE crítico? | Inspector → EventBridge Rule (severity=CRITICAL, type=ECR) → Lambda → CI/CD API |
| ¿Event source de Inspector en EventBridge? | `aws.inspector2` |
| ¿Detail-type del evento? | `Inspector2 Finding` |
