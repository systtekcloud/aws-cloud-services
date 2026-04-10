# Escenarios: Saga Pattern

## Escenario 1: Timeout en el servicio de hoteles

**Situación:** El servicio de hoteles no responde en 60 segundos (HeartbeatSeconds).

**Comportamiento:**
```
ReservarVuelo  → OK (AB123 reservado)
ReservarHotel  → TIMEOUT (60s sin heartbeat)
               → Step Functions lanza States.HeartbeatTimeout
               → Catch → CancelarVuelo
CancelarVuelo  → OK (AB123 cancelado)
NotificarFallo → OK
SagaFallida    → END
```

**Qué se puede mejorar:** si el timeout es frecuente (servicio lento), aumentar `HeartbeatSeconds` o añadir un circuit breaker antes de la saga.

---

## Escenario 2: Compensación fallida (estado inconsistente)

**Situación:** Falla `ReservarCoche`. Se intenta `CancelarHotel` pero el servicio de hoteles también está caído.

**Comportamiento:**
```
CancelarHotel → falla 3 veces (MaxAttempts=3)
             → Catch → CompensacionFallida
             → SNS alerta "compensacion_fallida" (PagerDuty)
             → SagaInconsistente (estado FAIL)
```

**Resolución manual:**
```bash
# Ver sagas en estado inconsistente
aws dynamodb query \
  --table-name sagas-prod \
  --index-name status-index \
  --key-condition-expression "#s = :s" \
  --expression-attribute-names '{"#s": "status"}' \
  --expression-attribute-values '{":s": {"S": "compensacion_fallida"}}'

# Compensar manualmente
aws stepfunctions start-execution \
  --state-machine-arn arn:aws:states:...:stateMachine:saga-compensacion-manual \
  --input '{"saga_id": "...", "pasos_a_cancelar": ["vuelo", "hotel"]}'
```

**Proceso de reconciliación nocturna:** Lambda schedulada que detecta sagas con TTL vencido sin status=completada y ejecuta compensaciones pendientes.

---

## Escenario 3: Saga coreografiada (alternativa sin Step Functions)

**Para comparación:** el mismo flujo sin orquestador central.

```
POST /reservas → Lambda → EventBridge: reserva.iniciada
                                │
                                ▼ (rule: reserva.iniciada)
                         servicio-vuelos → reserva vuelo
                         → EventBridge: vuelo.reservado o vuelo.fallido

                         vuelo.reservado → servicio-hoteles → ...
                         hotel.reservado → servicio-coches  → ...
                         coches.reservado → notificacion.exito

                         (si fallo en cualquier punto):
                         vuelo.fallido → (ningún compensador registrado ← problema)
                         hotel.fallido → Lambda → EventBridge: cancelar.vuelo
                                              → EventBridge: notificacion.fallo
```

**Problemas de la versión coreografiada:**
1. ¿Quién sabe que hay que cancelar el vuelo cuando falla el hotel? Hay que registrar un handler explícito para `hotel.fallido` que también sepa qué pasos anteriores deshacer.
2. Si el handler de `hotel.fallido` falla: la saga queda en estado inconsistente sin que nadie lo detecte.
3. Para saber el estado de una saga: hay que correlacionar todos los eventos en CloudWatch Logs.

**Cuándo usar coreografía:** si hay 2-3 pasos, no hay compensaciones complejas, y el equipo prefiere bajo acoplamiento sobre debugging sencillo.

---

## Escenario 4: Saga con paso paralelo

**Extensión:** reservar vuelo de ida Y vuelta en paralelo (dos aerolíneas distintas).

```
Step Functions Parallel state:
  ├─ Rama A: ReservarVueloIda (aerolínea 1)
  └─ Rama B: ReservarVueloVuelta (aerolínea 2)
        │
        ▼ (ambas deben completar)
  ReservarHotel → ReservarCoche → ...

  Si cualquier rama falla:
    Parallel Catch → CancelarVueloIda + CancelarVueloVuelta (paralelo)
                  → NotificarFallo
```

**ASL para el estado Parallel:**
```json
"ReservarVuelos": {
  "Type": "Parallel",
  "Branches": [
    { "StartAt": "ReservarVueloIda", "States": { ... } },
    { "StartAt": "ReservarVueloVuelta", "States": { ... } }
  ],
  "Catch": [{
    "ErrorEquals": ["States.ALL"],
    "Next": "CancelarVuelos"
  }],
  "Next": "ReservarHotel"
}
```
