# Lab 03.04 — Custom Config Rule con Lambda

> **Coste:** ~$0.20 (Lambda + Config evaluaciones) | **Prerrequisito:** lab 03.01 completado

---

## Objetivo

Crear una Lambda custom rule que verifica que las EC2 tienen el tag `Environment`. Configurar remediation via Lambda que añade el tag automáticamente cuando falta.

---

## Paso 1 — Crear la Lambda de evaluación (custom rule)

```bash
export AWS_REGION="eu-west-1"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# IAM Role para la Lambda de evaluación
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
  --role-name "lab03-custom-rule-lambda-role" \
  --assume-role-policy-document file:///tmp/lambda-trust.json

aws iam attach-role-policy \
  --role-name "lab03-custom-rule-lambda-role" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

# Permiso para reportar evaluaciones a Config
cat > /tmp/config-eval-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["config:PutEvaluations"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["ec2:DescribeInstances", "ec2:DescribeTags"],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "lab03-custom-rule-lambda-role" \
  --policy-name "lab03-config-eval-policy" \
  --policy-document file:///tmp/config-eval-policy.json

LAMBDA_ROLE_ARN=$(aws iam get-role \
  --role-name "lab03-custom-rule-lambda-role" \
  --query 'Role.Arn' --output text)

echo "Lambda Role ARN: $LAMBDA_ROLE_ARN"
sleep 10  # esperar propagación del rol
```

### Código de la Lambda

```bash
cat > /tmp/config_rule_lambda.py <<'EOF'
import json
import boto3

ec2 = boto3.client('ec2')
config_client = boto3.client('config')

def evaluate_compliance(configuration_item):
    """
    Evalúa si una EC2 tiene el tag 'Environment'.
    Retorna COMPLIANT o NON_COMPLIANT.
    """
    if configuration_item['resourceType'] != 'AWS::EC2::Instance':
        return 'NOT_APPLICABLE'

    resource_id = configuration_item['resourceId']

    try:
        response = ec2.describe_instances(InstanceIds=[resource_id])
        reservations = response.get('Reservations', [])
        if not reservations:
            return 'NOT_APPLICABLE'

        instance = reservations[0]['Instances'][0]
        tags = {tag['Key']: tag['Value'] for tag in instance.get('Tags', [])}

        if 'Environment' in tags:
            return 'COMPLIANT'
        else:
            return 'NON_COMPLIANT'
    except Exception as e:
        print(f"Error evaluando {resource_id}: {e}")
        return 'NOT_APPLICABLE'

def lambda_handler(event, context):
    invoking_event = json.loads(event['invokingEvent'])
    configuration_item = invoking_event.get('configurationItem', {})

    compliance = evaluate_compliance(configuration_item)

    evaluation = {
        'ComplianceResourceType': configuration_item.get('resourceType', ''),
        'ComplianceResourceId': configuration_item.get('resourceId', ''),
        'ComplianceType': compliance,
        'OrderingTimestamp': configuration_item.get('configurationItemCaptureTime', '')
    }

    config_client.put_evaluations(
        Evaluations=[evaluation],
        ResultToken=event['resultToken']
    )

    print(f"Recurso {evaluation['ComplianceResourceId']}: {compliance}")
    return {'compliance': compliance}
EOF

# Empaquetar
cd /tmp && zip config_rule_lambda.zip config_rule_lambda.py

# Crear Lambda
aws lambda create-function \
  --function-name "lab03-ec2-tag-check" \
  --runtime python3.12 \
  --role "$LAMBDA_ROLE_ARN" \
  --handler config_rule_lambda.lambda_handler \
  --zip-file fileb:///tmp/config_rule_lambda.zip \
  --timeout 30 \
  --region "$AWS_REGION"

LAMBDA_ARN=$(aws lambda get-function \
  --function-name "lab03-ec2-tag-check" \
  --query 'Configuration.FunctionArn' --output text \
  --region "$AWS_REGION")

echo "Lambda ARN: $LAMBDA_ARN"
```

---

## Paso 2 — Dar permiso a Config para invocar la Lambda

```bash
aws lambda add-permission \
  --function-name "lab03-ec2-tag-check" \
  --statement-id "AWSConfigInvoke" \
  --action "lambda:InvokeFunction" \
  --principal "config.amazonaws.com" \
  --source-account "$ACCOUNT_ID" \
  --region "$AWS_REGION"
```

---

## Paso 3 — Crear la Custom Config Rule

```bash
aws configservice put-config-rule \
  --config-rule "{
    \"ConfigRuleName\": \"ec2-required-tag-environment\",
    \"Description\": \"Verifica que las EC2 tienen el tag Environment\",
    \"Source\": {
      \"Owner\": \"CUSTOM_LAMBDA\",
      \"SourceIdentifier\": \"${LAMBDA_ARN}\",
      \"SourceDetails\": [
        {
          \"EventSource\": \"aws.config\",
          \"MessageType\": \"ConfigurationItemChangeNotification\"
        }
      ]
    },
    \"Scope\": {
      \"ComplianceResourceTypes\": [\"AWS::EC2::Instance\"]
    }
  }" \
  --region "$AWS_REGION"

echo "Custom rule creada: ec2-required-tag-environment"
```

---

## Paso 4 — Probar con una EC2 sin tag

Si tienes EC2 en la cuenta, fuerza la evaluación:

```bash
aws configservice start-config-rules-evaluation \
  --config-rule-names ec2-required-tag-environment \
  --region "$AWS_REGION"

sleep 30

# Ver recursos NON_COMPLIANT
aws configservice get-compliance-details-by-config-rule \
  --config-rule-name ec2-required-tag-environment \
  --compliance-types NON_COMPLIANT \
  --region "$AWS_REGION" \
  --query 'EvaluationResults[].{Recurso:EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId,Estado:ComplianceType}' \
  --output table
```

---

## Paso 5 — Lambda de remediation (añade el tag automáticamente)

```bash
cat > /tmp/remediation_lambda.py <<'EOF'
import json
import boto3

ec2 = boto3.client('ec2')

def lambda_handler(event, context):
    """
    Remediation lambda: añade el tag 'Environment=unknown' a EC2 sin tag.
    En producción, este valor se determinaría por convención de naming u otra fuente.
    """
    resource_id = event.get('resourceId') or event.get('ResourceId')

    if not resource_id:
        print("No se recibió resourceId")
        return {'status': 'ERROR', 'message': 'No resourceId'}

    try:
        ec2.create_tags(
            Resources=[resource_id],
            Tags=[{'Key': 'Environment', 'Value': 'unknown-auto-tagged'}]
        )
        print(f"Tag añadido a {resource_id}: Environment=unknown-auto-tagged")
        return {'status': 'SUCCESS', 'resourceId': resource_id}
    except Exception as e:
        print(f"Error añadiendo tag a {resource_id}: {e}")
        raise
EOF

cd /tmp && zip remediation_lambda.zip remediation_lambda.py

# Crear Lambda de remediation (mismo rol, necesita ec2:CreateTags)
cat > /tmp/tag-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["ec2:CreateTags", "ec2:DescribeInstances"],
    "Resource": "*"
  }]
}
EOF

aws iam put-role-policy \
  --role-name "lab03-custom-rule-lambda-role" \
  --policy-name "lab03-ec2-tag-policy" \
  --policy-document file:///tmp/tag-policy.json

aws lambda create-function \
  --function-name "lab03-ec2-tag-remediation" \
  --runtime python3.12 \
  --role "$LAMBDA_ROLE_ARN" \
  --handler remediation_lambda.lambda_handler \
  --zip-file fileb:///tmp/remediation_lambda.zip \
  --timeout 30 \
  --region "$AWS_REGION"

REMEDIATION_LAMBDA_ARN=$(aws lambda get-function \
  --function-name "lab03-ec2-tag-remediation" \
  --query 'Configuration.FunctionArn' --output text \
  --region "$AWS_REGION")

echo "Remediation Lambda ARN: $REMEDIATION_LAMBDA_ARN"
```

---

## Paso 6 — Limpiar

```bash
aws lambda delete-function --function-name "lab03-ec2-tag-check" --region "$AWS_REGION"
aws lambda delete-function --function-name "lab03-ec2-tag-remediation" --region "$AWS_REGION"
aws configservice delete-config-rule --config-rule-name "ec2-required-tag-environment" --region "$AWS_REGION"
aws iam delete-role-policy --role-name "lab03-custom-rule-lambda-role" --policy-name "lab03-config-eval-policy"
aws iam delete-role-policy --role-name "lab03-custom-rule-lambda-role" --policy-name "lab03-ec2-tag-policy"
aws iam detach-role-policy --role-name "lab03-custom-rule-lambda-role" --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
aws iam delete-role --role-name "lab03-custom-rule-lambda-role"
```
