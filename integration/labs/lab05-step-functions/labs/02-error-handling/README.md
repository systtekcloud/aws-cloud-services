# Lab 05-B: Error Handling

**Objetivo:** Configurar retry con backoff exponencial, Catch para routing a estados de compensación, timeouts por estado, y heartbeat para long-running tasks.

**Tiempo estimado:** 40 min  
**Coste estimado:** $0

---

## Concepto: El flujo de error en Step Functions

```
Estado Task ejecuta
    │
    ├─ Éxito → Next state
    │
    └─ Error
         │
         ▼
    ¿Hay Retry que aplica?
         │
    ┌────┴────┐
   Sí        No
    │          │
    ▼          ▼
Espera      ¿Hay Catch que aplica?
IntervalSeconds   │
(con backoff)  ┌──┴──┐
    │         Sí    No
    │          │     │
    ▼          ▼     ▼
Reintenta  Ir a   Falla la
(hasta     estado  ejecución
MaxAttempts)  de   completa
             compensación
```

---

## Paso 1: Retry con backoff exponencial

```json
// Configuración de Retry en ASL:
"Retry": [
  {
    "ErrorEquals": ["Lambda.TooManyRequestsException"],
    "IntervalSeconds": 1,
    "MaxAttempts": 5,
    "BackoffRate": 2,
    "JitterStrategy": "FULL"
  },
  {
    "ErrorEquals": ["MiErrorCustom"],
    "IntervalSeconds": 10,
    "MaxAttempts": 3,
    "BackoffRate": 1.5,
    "MaxDelaySeconds": 60
  },
  {
    "ErrorEquals": ["States.ALL"],
    "IntervalSeconds": 2,
    "MaxAttempts": 2,
    "BackoffRate": 2
  }
]
```

**Errores predefinidos de Step Functions:**
| Error | Cuándo |
|-------|--------|
| `States.ALL` | Cualquier error |
| `States.TaskFailed` | La task lanzó una excepción |
| `States.Timeout` | El estado superó TimeoutSeconds |
| `States.HeartbeatTimeout` | No recibió heartbeat a tiempo |
| `Lambda.TooManyRequestsException` | Lambda throttling |
| `Lambda.ServiceException` | Error interno de Lambda |

**JitterStrategy: FULL** — aleatoriza el tiempo de espera entre 0 y el calculado. Evita el efecto "thundering herd" cuando muchas ejecuciones fallan simultáneamente.

---

## Paso 2: Catch para compensación

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
SFN_ROLE_ARN=$(aws iam get-role --role-name lab05-sfn-role --query 'Role.Arn' --output text 2>/dev/null || \
  echo "ROLE_PENDIENTE")

# State machine con retry + catch + compensación
cat > /tmp/sfn-error-handling.json << EOF
{
  "Comment": "Lab 05B — Error handling avanzado",
  "StartAt": "ProcesarTransaccion",
  "States": {
    "ProcesarTransaccion": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:eu-west-1:$ACCOUNT_ID:function:lab05-procesar-pago",
      "TimeoutSeconds": 30,
      "HeartbeatSeconds": 10,
      "Retry": [
        {
          "ErrorEquals": ["Lambda.TooManyRequestsException", "Lambda.ServiceException"],
          "IntervalSeconds": 2,
          "MaxAttempts": 3,
          "BackoffRate": 2,
          "JitterStrategy": "FULL"
        },
        {
          "ErrorEquals": ["PagoError"],
          "IntervalSeconds": 5,
          "MaxAttempts": 2,
          "BackoffRate": 1.5
        }
      ],
      "Catch": [
        {
          "ErrorEquals": ["PagoError"],
          "ResultPath": "$.error_info",
          "Next": "CompensarReserva"
        },
        {
          "ErrorEquals": ["States.Timeout"],
          "ResultPath": "$.error_info",
          "Next": "NotificarTimeout"
        },
        {
          "ErrorEquals": ["States.ALL"],
          "ResultPath": "$.error_info",
          "Next": "ManejarErrorGeneral"
        }
      ],
      "Next": "TransaccionExitosa"
    },
    "TransaccionExitosa": {
      "Type": "Succeed"
    },
    "CompensarReserva": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:eu-west-1:$ACCOUNT_ID:function:lab05-enviar-confirmacion",
      "Comment": "Liberar reserva tras fallo de pago",
      "Parameters": {
        "accion": "cancelar",
        "pedido.$": "$.pedido",
        "motivo.$": "$.error_info.Cause"
      },
      "End": true
    },
    "NotificarTimeout": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:eu-west-1:$ACCOUNT_ID:function:lab05-enviar-confirmacion",
      "Parameters": {
        "accion": "timeout_alert",
        "pedido.$": "$.pedido"
      },
      "Next": "FalloTimeout"
    },
    "FalloTimeout": {
      "Type": "Fail",
      "Error": "TimeoutExcedido",
      "Cause": "La transacción superó el tiempo máximo"
    },
    "ManejarErrorGeneral": {
      "Type": "Pass",
      "Parameters": {
        "mensaje": "Error no esperado capturado",
        "error.$": "$.error_info"
      },
      "Next": "FalloGeneral"
    },
    "FalloGeneral": {
      "Type": "Fail",
      "Error": "ErrorGeneral"
    }
  }
}
EOF

SFN_EH_ARN=$(aws stepfunctions create-state-machine \
  --name lab05-error-handling \
  --definition file:///tmp/sfn-error-handling.json \
  --role-arn "$SFN_ROLE_ARN" \
  --type STANDARD \
  --region eu-west-1 \
  --query 'stateMachineArn' --output text)

echo "State Machine (error handling): $SFN_EH_ARN"
```

## Paso 3: Observar el retry en acción

```bash
# Ejecutar varias veces — debido al 10% de fallo random verás retries
for i in 1 2 3; do
  EXEC=$(aws stepfunctions start-execution \
    --state-machine-arn "$SFN_EH_ARN" \
    --name "eh-test-$i-$(date +%s)" \
    --input "{\"pedido\": {\"pedido_id\": \"PED-$i\", \"cliente_id\": \"cli-$i\", \"total\": 99}}" \
    --region eu-west-1 \
    --query 'executionArn' --output text)
  echo "Ejecución $i: $EXEC"
done

sleep 30

# Ver resultados
aws stepfunctions list-executions \
  --state-machine-arn "$SFN_EH_ARN" \
  --region eu-west-1 \
  --query 'executions[*].{Name: name, Status: status}' \
  --output table
```

## Paso 4: TimeoutSeconds y HeartbeatSeconds

```
TimeoutSeconds: tiempo máximo que puede durar un estado Task.
  Si la Lambda no responde en ese tiempo → States.Timeout

HeartbeatSeconds: para waitForTaskToken.
  El worker externo debe llamar send-task-heartbeat cada N segundos
  o Step Functions asume que murió → States.HeartbeatTimeout

Ejemplo con waitForTaskToken:
  "Resource": "arn:aws:states:::lambda:invoke.waitForTaskToken"
  "HeartbeatSeconds": 60
  → El worker tiene 60s para hacer heartbeat o la task expira
```

```bash
# Verificar timeout en una ejecución con función lenta
cat > /tmp/sfn-timeout-test.py << 'EOF'
import time
def handler(event, context):
    time.sleep(60)  # Más lento que el timeout de 10s
    return {"ok": True}
EOF
cd /tmp && zip sfn-timeout.zip sfn-timeout-test.py
ROLE_ARN=$(aws iam get-role --role-name lab05-sfn-lambda-role 2>/dev/null --query 'Role.Arn' --output text || \
           aws iam get-role --role-name lab01-lambda-basic-role --query 'Role.Arn' --output text)
aws lambda create-function \
  --function-name lab05-slow-function \
  --runtime python3.12 \
  --handler sfn-timeout-test.handler \
  --role "$ROLE_ARN" \
  --zip-file fileb:///tmp/sfn-timeout.zip \
  --timeout 70 \
  --region eu-west-1 2>/dev/null || true

# State machine con timeout estricto de 10s
cat > /tmp/sfn-timeout-sm.json << EOF
{
  "StartAt": "TareaLenta",
  "States": {
    "TareaLenta": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:eu-west-1:$ACCOUNT_ID:function:lab05-slow-function",
      "TimeoutSeconds": 10,
      "Catch": [{"ErrorEquals": ["States.Timeout"], "Next": "TimeoutCapturado"}],
      "End": true
    },
    "TimeoutCapturado": {
      "Type": "Fail",
      "Error": "TareaExpirada",
      "Cause": "La tarea superó los 10 segundos"
    }
  }
}
EOF

aws stepfunctions create-state-machine \
  --name lab05-timeout-demo \
  --definition file:///tmp/sfn-timeout-sm.json \
  --role-arn "$SFN_ROLE_ARN" \
  --type STANDARD \
  --region eu-west-1 > /dev/null

TIMEOUT_ARN=$(aws stepfunctions list-state-machines --region eu-west-1 \
  --query "stateMachines[?name=='lab05-timeout-demo'].stateMachineArn" --output text)

aws stepfunctions start-execution \
  --state-machine-arn "$TIMEOUT_ARN" \
  --input '{}' \
  --region eu-west-1 > /dev/null

echo "Ejecución iniciada. En ~15s verás Status: FAILED con error TareaExpirada"
sleep 20
aws stepfunctions list-executions \
  --state-machine-arn "$TIMEOUT_ARN" \
  --region eu-west-1 \
  --query 'executions[0].{Status: status, StopDate: stopDate}'
```

## Limpieza

```bash
for sm in lab05-error-handling lab05-timeout-demo; do
  ARN=$(aws stepfunctions list-state-machines --region eu-west-1 \
    --query "stateMachines[?name=='$sm'].stateMachineArn" --output text)
  [ -n "$ARN" ] && aws stepfunctions delete-state-machine --state-machine-arn "$ARN" --region eu-west-1
done
aws lambda delete-function --function-name lab05-slow-function --region eu-west-1 2>/dev/null || true
```
