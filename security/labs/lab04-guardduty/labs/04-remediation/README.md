# Lab 04.04 — Respuesta automática: EventBridge → Lambda + SNS

> **Coste:** ~$0.10 (Lambda + SNS) | **Prerrequisito:** lab 04.01 completado

---

## Objetivo

Crear una respuesta automática a findings de GuardDuty con severidad HIGH: una Lambda que aísla la EC2 afectada (cambia su Security Group a cuarentena) y un SNS que notifica al equipo. Verificar el flujo completo con un sample finding.

---

## Arquitectura

```
GuardDuty finding (severity HIGH)
        │
        ▼
  EventBridge Rule
  (filtra por severidad >= 7)
        │
        ├──────────────────────────────────────────────────┐
        ▼                                                  ▼
 Lambda: aísla EC2                                SNS Topic
 (cambia SG a quarantine-sg)                 (email/Slack al equipo)
        │
        ▼
 EC2 queda sin conectividad
 (solo permite tráfico de respuesta
  a incidentes)
```

---

## Paso 1 — Variables

```bash
export AWS_REGION="eu-west-1"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

DETECTOR_ID=$(aws guardduty list-detectors \
  --region "$AWS_REGION" \
  --query 'DetectorIds[0]' --output text)

echo "Detector ID: $DETECTOR_ID"
echo "Account ID: $ACCOUNT_ID"
```

---

## Paso 2 — Crear Security Group de cuarentena

```bash
DEFAULT_VPC=$(aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)

QUARANTINE_SG=$(aws ec2 create-security-group \
  --group-name "lab04-quarantine-sg" \
  --description "Security Group de cuarentena — sin acceso entrante ni saliente" \
  --vpc-id "$DEFAULT_VPC" \
  --query 'GroupId' --output text)

# Eliminar la regla de egress por defecto (permite todo el tráfico saliente)
aws ec2 revoke-security-group-egress \
  --group-id "$QUARANTINE_SG" \
  --protocol -1 \
  --cidr 0.0.0.0/0 2>/dev/null || echo "Regla egress ya eliminada, OK"

echo "Quarantine SG: $QUARANTINE_SG"
```

---

## Paso 3 — Crear SNS Topic para notificaciones

```bash
SNS_ARN=$(aws sns create-topic \
  --name "lab04-guardduty-alerts" \
  --region "$AWS_REGION" \
  --query 'TopicArn' --output text)

echo "SNS Topic: $SNS_ARN"

# Suscribirse al topic (reemplaza con tu email)
# aws sns subscribe \
#   --topic-arn "$SNS_ARN" \
#   --protocol email \
#   --notification-endpoint "tu-email@ejemplo.com" \
#   --region "$AWS_REGION"
```

---

## Paso 4 — Crear IAM Role para la Lambda

```bash
cat > /tmp/lambda-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name "lab04-guardduty-remediation-role" \
  --assume-role-policy-document file:///tmp/lambda-trust.json

aws iam attach-role-policy \
  --role-name "lab04-guardduty-remediation-role" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

cat > /tmp/remediation-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:ModifyInstanceAttribute",
        "ec2:DescribeSecurityGroups"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "sns:Publish",
      "Resource": "${SNS_ARN}"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "lab04-guardduty-remediation-role" \
  --policy-name "lab04-ec2-isolate-policy" \
  --policy-document file:///tmp/remediation-policy.json

LAMBDA_ROLE_ARN=$(aws iam get-role \
  --role-name "lab04-guardduty-remediation-role" \
  --query 'Role.Arn' --output text)

echo "Lambda Role ARN: $LAMBDA_ROLE_ARN"
sleep 10  # esperar propagación del rol
```

---

## Paso 5 — Crear Lambda de aislamiento

```bash
cat > /tmp/guardduty_remediation.py <<'EOF'
import json
import boto3
import os

ec2 = boto3.client('ec2')
sns = boto3.client('sns')

QUARANTINE_SG = os.environ.get('QUARANTINE_SG_ID', '')
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', '')

def lambda_handler(event, context):
    """
    Responde a findings de GuardDuty con severidad HIGH.
    1. Aísla la EC2 afectada cambiando su Security Group a cuarentena
    2. Notifica al equipo via SNS
    """
    print(f"Evento recibido: {json.dumps(event, default=str)}")

    # El evento de EventBridge contiene el finding en event['detail']
    finding = event.get('detail', {})
    finding_type = finding.get('type', 'Unknown')
    severity = finding.get('severity', 0)
    account_id = finding.get('accountId', 'Unknown')
    region = finding.get('region', 'Unknown')

    resource_type = finding.get('resource', {}).get('resourceType', 'Unknown')

    message = f"""
GuardDuty Finding - Acción de aislamiento ejecutada

Tipo: {finding_type}
Severidad: {severity}
Cuenta: {account_id}
Región: {region}
Recurso: {resource_type}
"""

    # Si el recurso es una EC2, aislarla
    if resource_type == 'Instance':
        instance_id = finding.get('resource', {}).get(
            'instanceDetails', {}).get('instanceId', '')

        if instance_id and QUARANTINE_SG:
            try:
                # Cambiar el Security Group a cuarentena
                ec2.modify_instance_attribute(
                    InstanceId=instance_id,
                    Groups=[QUARANTINE_SG]
                )
                message += f"\nACCIÓN: EC2 {instance_id} aislada en Security Group de cuarentena"
                print(f"EC2 {instance_id} aislada en SG: {QUARANTINE_SG}")
            except Exception as e:
                message += f"\nERROR al aislar {instance_id}: {str(e)}"
                print(f"Error: {e}")
        else:
            message += f"\nNOTA: No se pudo aislar (instance_id={instance_id}, quarantine_sg={QUARANTINE_SG})"
    else:
        message += f"\nNOTA: Recurso tipo {resource_type} — revisar manualmente"

    # Notificar al equipo via SNS
    if SNS_TOPIC_ARN:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f"[ALERTA] GuardDuty HIGH: {finding_type}",
            Message=message
        )
        print(f"Notificación enviada a SNS: {SNS_TOPIC_ARN}")

    return {
        'statusCode': 200,
        'finding_type': finding_type,
        'severity': severity,
        'action': 'isolation_attempted'
    }
EOF

cd /tmp && zip guardduty_remediation.zip guardduty_remediation.py

LAMBDA_ARN=$(aws lambda create-function \
  --function-name "lab04-guardduty-isolate" \
  --runtime python3.12 \
  --role "$LAMBDA_ROLE_ARN" \
  --handler guardduty_remediation.lambda_handler \
  --zip-file fileb:///tmp/guardduty_remediation.zip \
  --timeout 30 \
  --environment "Variables={QUARANTINE_SG_ID=${QUARANTINE_SG},SNS_TOPIC_ARN=${SNS_ARN}}" \
  --region "$AWS_REGION" \
  --query 'FunctionArn' --output text)

echo "Lambda ARN: $LAMBDA_ARN"
```

---

## Paso 6 — Crear EventBridge Rule

```bash
# Crear EventBridge Rule que reacciona a findings GuardDuty con severity >= 7 (HIGH)
RULE_ARN=$(aws events put-rule \
  --name "lab04-guardduty-high-severity" \
  --description "Reacciona a findings GuardDuty HIGH severity" \
  --event-pattern '{
    "source": ["aws.guardduty"],
    "detail-type": ["GuardDuty Finding"],
    "detail": {
      "severity": [{"numeric": [">=", 7]}]
    }
  }' \
  --state ENABLED \
  --region "$AWS_REGION" \
  --query 'RuleArn' --output text)

echo "EventBridge Rule ARN: $RULE_ARN"
```

### Añadir targets: Lambda + SNS

```bash
# Dar permiso a EventBridge para invocar la Lambda
aws lambda add-permission \
  --function-name "lab04-guardduty-isolate" \
  --statement-id "EventBridgeInvoke" \
  --action "lambda:InvokeFunction" \
  --principal "events.amazonaws.com" \
  --source-arn "$RULE_ARN" \
  --region "$AWS_REGION"

# Crear policy para que EventBridge publique en SNS
cat > /tmp/sns-events-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "events.amazonaws.com"},
    "Action": "SNS:Publish",
    "Resource": "${SNS_ARN}"
  }]
}
EOF

aws sns set-topic-attributes \
  --topic-arn "$SNS_ARN" \
  --attribute-name Policy \
  --attribute-value file:///tmp/sns-events-policy.json \
  --region "$AWS_REGION"

# Añadir targets a la regla
aws events put-targets \
  --rule "lab04-guardduty-high-severity" \
  --targets "[
    {
      \"Id\": \"lambda-target\",
      \"Arn\": \"${LAMBDA_ARN}\"
    },
    {
      \"Id\": \"sns-target\",
      \"Arn\": \"${SNS_ARN}\"
    }
  ]" \
  --region "$AWS_REGION"

echo "Targets añadidos: Lambda + SNS"
```

---

## Paso 7 — Probar el flujo completo

```bash
# Generar sample finding de severidad HIGH (BitcoinTool = severity 8.0)
aws guardduty create-sample-findings \
  --detector-id "$DETECTOR_ID" \
  --finding-types "CryptoCurrency:EC2/BitcoinTool.B" \
  --region "$AWS_REGION"

echo "Sample finding HIGH generado — esperando 30s para que EventBridge procese..."
sleep 30

# Ver logs de la Lambda para confirmar que se ejecutó
LOG_GROUP="/aws/lambda/lab04-guardduty-isolate"

aws logs describe-log-streams \
  --log-group-name "$LOG_GROUP" \
  --order-by LastEventTime \
  --descending \
  --limit 1 \
  --region "$AWS_REGION" \
  --query 'logStreams[0].logStreamName' \
  --output text | xargs -I {} aws logs get-log-events \
    --log-group-name "$LOG_GROUP" \
    --log-stream-name "{}" \
    --region "$AWS_REGION" \
    --query 'events[].message' \
    --output table
```

---

## ¿Por qué GuardDuty no puede invocar SNS directamente?

```
GuardDuty genera eventos pero NO tiene integración directa con SNS, Lambda, etc.
Es un servicio de detección puro.

Arquitectura correcta:
GuardDuty → EventBridge → [Lambda, SNS, SQS, Step Functions...]

Ventajas del patrón EventBridge-intermedio:
1. Filtrado: solo reaccionar a findings HIGH (no a todos)
2. Múltiples targets: Lambda Y SNS simultáneamente
3. Input Transformer: modificar el payload antes de enviarlo
4. Retry automático: EventBridge reintenta si el target falla
5. Dead letter queue: findings no procesados van a SQS DLQ
```

---

## Paso 8 — Limpiar

```bash
# Eliminar targets y regla EventBridge
aws events remove-targets \
  --rule "lab04-guardduty-high-severity" \
  --ids "lambda-target" "sns-target" \
  --region "$AWS_REGION"

aws events delete-rule \
  --name "lab04-guardduty-high-severity" \
  --region "$AWS_REGION"

# Eliminar Lambda
aws lambda delete-function \
  --function-name "lab04-guardduty-isolate" \
  --region "$AWS_REGION"

# Eliminar SNS
aws sns delete-topic --topic-arn "$SNS_ARN" --region "$AWS_REGION"

# Eliminar SG de cuarentena
aws ec2 delete-security-group --group-id "$QUARANTINE_SG"

# Eliminar IAM Role
aws iam delete-role-policy \
  --role-name "lab04-guardduty-remediation-role" \
  --policy-name "lab04-ec2-isolate-policy"

aws iam detach-role-policy \
  --role-name "lab04-guardduty-remediation-role" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

aws iam delete-role --role-name "lab04-guardduty-remediation-role"

echo "Limpieza completa"
```
