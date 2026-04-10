# Lab 05-A: Orchestration Basics

**Objetivo:** Crear una state machine que orqueste un flujo de 3 pasos (validar → procesar → notificar), ejecutarla con CLI, y observar el flujo visual en la consola AWS.

**Tiempo estimado:** 45 min  
**Coste estimado:** $0 (primeras 4.000 transiciones gratis en Standard)

---

## Arquitectura del workflow

```
[Input: pedido]
      │
      ▼
ValidarPedido (Lambda)
      │
   ┌──┴──┐
válido inválido
   │       │
   ▼       ▼
ProcesarPago  PedidoRechazado (Fail)
   │
   ▼
EnviarConfirmacion (Lambda)
   │
   ▼
[Succeed]
```

---

## Paso 1: Funciones Lambda para cada tarea

```bash
ROLE_ARN=$(aws iam get-role \
  --role-name lab01-lambda-basic-role \
  --query 'Role.Arn' --output text 2>/dev/null)

# Si el rol del lab01 no existe, crear uno nuevo
if [ -z "$ROLE_ARN" ]; then
  aws iam create-role \
    --role-name lab05-sfn-lambda-role \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  aws iam attach-role-policy \
    --role-name lab05-sfn-lambda-role \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  ROLE_ARN=$(aws iam get-role --role-name lab05-sfn-lambda-role --query 'Role.Arn' --output text)
  sleep 10
fi

# Función: validar pedido
cat > /tmp/sfn-validate.py << 'EOF'
def handler(event, context):
    pedido = event.get('pedido', {})
    if not pedido.get('cliente_id'):
        raise Exception("ValidacionError: cliente_id requerido")
    if pedido.get('total', 0) <= 0:
        raise Exception("ValidacionError: total debe ser > 0")
    return {**event, 'validado': True}
EOF
cd /tmp && zip sfn-validate.zip sfn-validate.py
aws lambda create-function \
  --function-name lab05-validar-pedido \
  --runtime python3.12 \
  --handler sfn-validate.handler \
  --role "$ROLE_ARN" \
  --zip-file fileb:///tmp/sfn-validate.zip \
  --region eu-west-1 2>/dev/null || \
aws lambda update-function-code \
  --function-name lab05-validar-pedido \
  --zip-file fileb:///tmp/sfn-validate.zip \
  --region eu-west-1

# Función: procesar pago
cat > /tmp/sfn-payment.py << 'EOF'
import random
def handler(event, context):
    # Simula procesamiento de pago (90% éxito)
    if random.random() < 0.1:
        raise Exception("PagoError: tarjeta rechazada")
    return {**event, 'pago_id': f"PAY-{random.randint(1000,9999)}", 'pago_ok': True}
EOF
cd /tmp && zip sfn-payment.zip sfn-payment.py
aws lambda create-function \
  --function-name lab05-procesar-pago \
  --runtime python3.12 \
  --handler sfn-payment.handler \
  --role "$ROLE_ARN" \
  --zip-file fileb:///tmp/sfn-payment.zip \
  --region eu-west-1 2>/dev/null || \
aws lambda update-function-code \
  --function-name lab05-procesar-pago \
  --zip-file fileb:///tmp/sfn-payment.zip \
  --region eu-west-1

# Función: enviar confirmación
cat > /tmp/sfn-confirm.py << 'EOF'
import json
def handler(event, context):
    print(f"Email enviado a cliente {event['pedido']['cliente_id']}: pago {event['pago_id']} confirmado")
    return {**event, 'confirmacion_enviada': True}
EOF
cd /tmp && zip sfn-confirm.zip sfn-confirm.py
aws lambda create-function \
  --function-name lab05-enviar-confirmacion \
  --runtime python3.12 \
  --handler sfn-confirm.handler \
  --role "$ROLE_ARN" \
  --zip-file fileb:///tmp/sfn-confirm.zip \
  --region eu-west-1 2>/dev/null || \
aws lambda update-function-code \
  --function-name lab05-enviar-confirmacion \
  --zip-file fileb:///tmp/sfn-confirm.zip \
  --region eu-west-1
```

## Paso 2: IAM Role para Step Functions

```bash
aws iam create-role \
  --role-name lab05-sfn-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "states.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' 2>/dev/null || true

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws iam put-role-policy \
  --role-name lab05-sfn-role \
  --policy-name invoke-lambdas \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"lambda:InvokeFunction\",
      \"Resource\": [
        \"arn:aws:lambda:eu-west-1:$ACCOUNT_ID:function:lab05-*\"
      ]
    }]
  }"

SFN_ROLE_ARN=$(aws iam get-role --role-name lab05-sfn-role --query 'Role.Arn' --output text)
```

## Paso 3: Crear la state machine

```bash
cat > /tmp/sfn-definition.json << EOF
{
  "Comment": "Lab 05 — Flujo básico de pedido",
  "StartAt": "ValidarPedido",
  "States": {
    "ValidarPedido": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:eu-west-1:$ACCOUNT_ID:function:lab05-validar-pedido",
      "ResultPath": null,
      "Next": "ProcesarPago",
      "Retry": [{
        "ErrorEquals": ["Lambda.ServiceException"],
        "IntervalSeconds": 2,
        "MaxAttempts": 2,
        "BackoffRate": 2
      }],
      "Catch": [{
        "ErrorEquals": ["Exception"],
        "ResultPath": "$.error",
        "Next": "PedidoRechazado"
      }]
    },
    "ProcesarPago": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:eu-west-1:$ACCOUNT_ID:function:lab05-procesar-pago",
      "Next": "EnviarConfirmacion",
      "Retry": [{
        "ErrorEquals": ["PagoError"],
        "IntervalSeconds": 5,
        "MaxAttempts": 2,
        "BackoffRate": 1.5
      }]
    },
    "EnviarConfirmacion": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:eu-west-1:$ACCOUNT_ID:function:lab05-enviar-confirmacion",
      "End": true
    },
    "PedidoRechazado": {
      "Type": "Fail",
      "Error": "PedidoInvalido",
      "Cause": "Validación o pago fallidos"
    }
  }
}
EOF

SFN_ARN=$(aws stepfunctions create-state-machine \
  --name lab05-pedido-workflow \
  --definition file:///tmp/sfn-definition.json \
  --role-arn "$SFN_ROLE_ARN" \
  --type STANDARD \
  --region eu-west-1 \
  --query 'stateMachineArn' \
  --output text)

echo "State Machine ARN: $SFN_ARN"
```

## Paso 4: Ejecutar y observar

```bash
# 4.1 Ejecución exitosa
EXEC_ARN=$(aws stepfunctions start-execution \
  --state-machine-arn "$SFN_ARN" \
  --name "ejecucion-$(date +%s)" \
  --input '{"pedido": {"pedido_id": "PED-001", "cliente_id": "cli-123", "total": 149.99}}' \
  --region eu-west-1 \
  --query 'executionArn' \
  --output text)

echo "Ejecución iniciada: $EXEC_ARN"

# 4.2 Esperar y ver el resultado
sleep 10
aws stepfunctions describe-execution \
  --execution-arn "$EXEC_ARN" \
  --region eu-west-1 \
  --query '{Status: status, Input: input, Output: output}' \
  --output json

# 4.3 Ver el historial de estados (cada transición)
aws stepfunctions get-execution-history \
  --execution-arn "$EXEC_ARN" \
  --region eu-west-1 \
  --query 'events[*].{Type: type, Time: timestamp}' \
  --output table

# 4.4 Ejecución con error de validación
EXEC_FAIL=$(aws stepfunctions start-execution \
  --state-machine-arn "$SFN_ARN" \
  --name "ejecucion-fallo-$(date +%s)" \
  --input '{"pedido": {"pedido_id": "PED-002", "total": -10}}' \
  --region eu-west-1 \
  --query 'executionArn' --output text)

sleep 5
aws stepfunctions describe-execution \
  --execution-arn "$EXEC_FAIL" \
  --region eu-west-1 \
  --query '{Status: status, StopDate: stopDate}' --output json
# Status debería ser FAILED

# 4.5 Listar todas las ejecuciones
aws stepfunctions list-executions \
  --state-machine-arn "$SFN_ARN" \
  --region eu-west-1 \
  --query 'executions[*].{Name: name, Status: status, Start: startDate}'
```

> **Tip consola:** En AWS Console → Step Functions → la state machine muestra el diagrama visual con cada estado coloreado (verde/rojo) según el resultado de la ejecución. Esencial para debugging.

## Limpieza

```bash
aws stepfunctions delete-state-machine --state-machine-arn "$SFN_ARN" --region eu-west-1
for fn in lab05-validar-pedido lab05-procesar-pago lab05-enviar-confirmacion; do
  aws lambda delete-function --function-name "$fn" --region eu-west-1 2>/dev/null || true
done
```
