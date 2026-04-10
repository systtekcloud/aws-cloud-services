# Lab 05-D: Saga Pattern

**Objetivo:** Implementar el patrón Saga para transacciones distribuidas con Step Functions. Cada paso tiene su transacción de compensación. Si cualquier paso falla, se ejecutan las compensaciones en orden inverso.

**Tiempo estimado:** 50 min  
**Coste estimado:** $0

---

## Concepto: Saga vs 2-Phase Commit

```
2-Phase Commit (2PC):
  Coordinador pregunta a todos los participantes: "¿puedes comprometerte?"
  Si todos dicen sí → COMMIT
  Si alguno dice no → ROLLBACK global
  ✓ Consistencia fuerte
  ✗ Acoplamiento temporal: todos los servicios deben estar disponibles
  ✗ Locks distribuidos → baja disponibilidad, no escala

Saga Pattern:
  Cada paso se confirma de forma local e independiente
  Si falla un paso → se ejecutan compensaciones de los pasos anteriores
  ✓ Sin locks distribuidos → alta disponibilidad
  ✓ Servicios independientes (pueden caer y recuperarse)
  ✗ Consistencia eventual (hay momentos de estado inconsistente)
  ✗ Compensaciones deben ser idempotentes
```

---

## Caso de uso: Reserva de viaje

```
Pasos normales (happy path):
  1. ReservarVuelo   → confirma asiento en aerolínea
  2. ReservarHotel   → bloquea habitación en hotel
  3. ReservarCoche   → asigna vehículo en rentacar

Si ReservarCoche falla:
  Compensaciones (en orden inverso):
  3. [falla]
  2. CancelarHotel   → libera la habitación
  1. CancelarVuelo   → libera el asiento

El cliente nunca queda con vuelo+hotel sin coche.
```

---

## Paso 1: Lambdas para cada servicio

```bash
ROLE_ARN=$(aws iam get-role --role-name lab05-sfn-lambda-role 2>/dev/null --query 'Role.Arn' --output text || \
           aws iam get-role --role-name lab01-lambda-basic-role --query 'Role.Arn' --output text)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Función de reserva (puede fallar con probabilidad configurable)
cat > /tmp/sfn-saga-reserve.py << 'EOF'
import json
import random

def handler(event, context):
    servicio = event.get('servicio', 'desconocido')
    fail_rate = float(event.get('fail_rate', 0))
    
    if random.random() < fail_rate:
        raise Exception(f"ReservaError: {servicio} no disponible")
    
    reservation_id = f"{servicio.upper()}-{random.randint(1000, 9999)}"
    print(f"Reserva OK: {servicio} → {reservation_id}")
    return {**event, f"{servicio}_id": reservation_id, f"{servicio}_ok": True}
EOF

# Función de cancelación (compensación — debe ser idempotente)
cat > /tmp/sfn-saga-cancel.py << 'EOF'
import json

def handler(event, context):
    servicio = event.get('servicio', 'desconocido')
    reservation_key = f"{servicio}_id"
    reservation_id = event.get(reservation_key, 'N/A')
    
    print(f"Cancelando: {servicio} reserva {reservation_id}")
    # Idempotente: si ya está cancelada, no falla
    return {**event, f"{servicio}_cancelado": True}
EOF

mkdir -p /tmp/sfn-saga
cp /tmp/sfn-saga-reserve.py /tmp/sfn-saga/
cp /tmp/sfn-saga-cancel.py /tmp/sfn-saga/

for func in reserve cancel; do
  cd /tmp/sfn-saga && zip sfn-saga-$func.zip sfn-saga-$func.py
  aws lambda create-function \
    --function-name "lab05-saga-$func" \
    --runtime python3.12 \
    --handler "sfn-saga-$func.handler" \
    --role "$ROLE_ARN" \
    --zip-file "fileb:///tmp/sfn-saga/sfn-saga-$func.zip" \
    --timeout 10 \
    --region eu-west-1 2>/dev/null || \
  aws lambda update-function-code \
    --function-name "lab05-saga-$func" \
    --zip-file "fileb:///tmp/sfn-saga/sfn-saga-$func.zip" \
    --region eu-west-1
done
```

## Paso 2: State machine Saga con compensaciones

```bash
SFN_ROLE_ARN=$(aws iam get-role --role-name lab05-sfn-role --query 'Role.Arn' --output text 2>/dev/null)

cat > /tmp/sfn-saga-definition.json << EOF
{
  "Comment": "Lab 05D — Saga Pattern: Reserva de viaje con compensaciones",
  "StartAt": "ReservarVuelo",
  "States": {
    "ReservarVuelo": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:eu-west-1:$ACCOUNT_ID:function:lab05-saga-reserve",
      "Parameters": {
        "servicio": "vuelo",
        "fail_rate.$": "$.vuelo_fail_rate",
        "viaje_id.$": "$.viaje_id"
      },
      "ResultPath": "$.vuelo",
      "Catch": [{
        "ErrorEquals": ["ReservaError", "Exception"],
        "ResultPath": "$.error",
        "Next": "FalloSinCompensacion"
      }],
      "Next": "ReservarHotel"
    },
    "ReservarHotel": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:eu-west-1:$ACCOUNT_ID:function:lab05-saga-reserve",
      "Parameters": {
        "servicio": "hotel",
        "fail_rate.$": "$.hotel_fail_rate",
        "viaje_id.$": "$.viaje_id",
        "vuelo_id.$": "$.vuelo.vuelo_id"
      },
      "ResultPath": "$.hotel",
      "Catch": [{
        "ErrorEquals": ["ReservaError", "Exception"],
        "ResultPath": "$.error",
        "Next": "CompensarVuelo"
      }],
      "Next": "ReservarCoche"
    },
    "ReservarCoche": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:eu-west-1:$ACCOUNT_ID:function:lab05-saga-reserve",
      "Parameters": {
        "servicio": "coche",
        "fail_rate.$": "$.coche_fail_rate",
        "viaje_id.$": "$.viaje_id",
        "vuelo_id.$": "$.vuelo.vuelo_id",
        "hotel_id.$": "$.hotel.hotel_id"
      },
      "ResultPath": "$.coche",
      "Catch": [{
        "ErrorEquals": ["ReservaError", "Exception"],
        "ResultPath": "$.error",
        "Next": "CompensarHotel"
      }],
      "Next": "ReservaCompleta"
    },
    "ReservaCompleta": {
      "Type": "Succeed"
    },
    "CompensarHotel": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:eu-west-1:$ACCOUNT_ID:function:lab05-saga-cancel",
      "Parameters": {
        "servicio": "hotel",
        "hotel_id.$": "$.hotel.hotel_id",
        "viaje_id.$": "$.viaje_id"
      },
      "ResultPath": "$.compensacion_hotel",
      "Next": "CompensarVuelo"
    },
    "CompensarVuelo": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:eu-west-1:$ACCOUNT_ID:function:lab05-saga-cancel",
      "Parameters": {
        "servicio": "vuelo",
        "vuelo_id.$": "$.vuelo.vuelo_id",
        "viaje_id.$": "$.viaje_id"
      },
      "ResultPath": "$.compensacion_vuelo",
      "Next": "ReservaFallida"
    },
    "FalloSinCompensacion": {
      "Type": "Fail",
      "Error": "VueloNoDisponible",
      "Cause": "Primer paso fallido — no hay nada que compensar"
    },
    "ReservaFallida": {
      "Type": "Fail",
      "Error": "SagaCompensada",
      "Cause": "Reserva fallida — compensaciones ejecutadas"
    }
  }
}
EOF

SAGA_ARN=$(aws stepfunctions create-state-machine \
  --name lab05-saga-viaje \
  --definition file:///tmp/sfn-saga-definition.json \
  --role-arn "$SFN_ROLE_ARN" \
  --type STANDARD \
  --region eu-west-1 \
  --query 'stateMachineArn' --output text)

echo "Saga State Machine: $SAGA_ARN"
```

## Paso 3: Probar el happy path y el camino de compensación

```bash
# 3.1 Happy path — sin fallos
echo "=== Happy Path ==="
EXEC_OK=$(aws stepfunctions start-execution \
  --state-machine-arn "$SAGA_ARN" \
  --name "saga-ok-$(date +%s)" \
  --input '{
    "viaje_id": "VJ-001",
    "vuelo_fail_rate": 0,
    "hotel_fail_rate": 0,
    "coche_fail_rate": 0
  }' \
  --region eu-west-1 \
  --query 'executionArn' --output text)

sleep 15
aws stepfunctions describe-execution \
  --execution-arn "$EXEC_OK" \
  --region eu-west-1 \
  --query '{Status: status}' --output text

# 3.2 Fallo en coche → compensa hotel y vuelo
echo ""
echo "=== Fallo en ReservarCoche → compensaciones ==="
EXEC_FAIL=$(aws stepfunctions start-execution \
  --state-machine-arn "$SAGA_ARN" \
  --name "saga-fail-coche-$(date +%s)" \
  --input '{
    "viaje_id": "VJ-002",
    "vuelo_fail_rate": 0,
    "hotel_fail_rate": 0,
    "coche_fail_rate": 1
  }' \
  --region eu-west-1 \
  --query 'executionArn' --output text)

sleep 20
aws stepfunctions describe-execution \
  --execution-arn "$EXEC_FAIL" \
  --region eu-west-1 \
  --query '{Status: status}' --output text

# Ver el historial completo (estados ejecutados)
echo ""
echo "=== Historial de estados (fallo con compensación) ==="
aws stepfunctions get-execution-history \
  --execution-arn "$EXEC_FAIL" \
  --region eu-west-1 \
  --query 'events[?type==`TaskStateEntered`].{State: stateEnteredEventDetails.name}' \
  --output table
# Debería mostrar: ReservarVuelo → ReservarHotel → ReservarCoche → CompensarHotel → CompensarVuelo → ReservaFallida
```

## Compensaciones idempotentes — clave del Saga

```python
# ✓ Compensación idempotente: puede llamarse varias veces con el mismo resultado
def cancelar_reserva_hotel(reservation_id):
    try:
        hotel_service.cancel(reservation_id)
    except ReservaYaCancelada:
        pass  # Ya estaba cancelada — OK
    return {"cancelado": True}

# ✗ No idempotente: si se llama 2 veces, cobra 2 veces el reembolso
def reembolsar(reservation_id, monto):
    banco.transferir(cliente, monto)  # PELIGRO si se llama 2 veces
```

**Para garantizar idempotencia:** usar un registro de estado en DynamoDB antes de ejecutar la compensación. Si ya existe el registro de cancelación → skip.

## Orchestration Saga vs Choreography Saga

```
Orchestration Saga (este lab — Step Functions):
  + Flujo centralizado y visible
  + Fácil debugging (historial completo)
  + Compensaciones explícitas en la state machine
  - Acoplamiento al orquestador

Choreography Saga (EventBridge):
  Cada servicio reacciona a eventos y publica eventos de compensación
  + Desacoplado
  - Difícil seguir el flujo (disperso en múltiples servicios)
  - Compensaciones implícitas (difícil garantizar orden)

Regla: usa orchestration cuando el flujo es complejo o la auditoría es crítica.
```

## Limpieza

```bash
aws stepfunctions delete-state-machine --state-machine-arn "$SAGA_ARN" --region eu-west-1
aws lambda delete-function --function-name lab05-saga-reserve --region eu-west-1 2>/dev/null || true
aws lambda delete-function --function-name lab05-saga-cancel --region eu-west-1 2>/dev/null || true
```
