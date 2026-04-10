# Saga vs Two-Phase Commit (2PC)

## Two-Phase Commit — por qué no funciona en microservicios

2PC requiere un coordinador que bloquea recursos en todos los participantes hasta confirmar:

```
Fase 1 (Prepare):
  Coordinador → "¿puedes hacer commit?"
  Vuelos DB   ← bloquea reserva
  Hoteles DB  ← bloquea habitación
  Coches DB   ← bloquea vehículo

Fase 2 (Commit o Abort):
  Si todos "sí" → Coordinador → "Commit"
  Si alguno "no" → Coordinador → "Abort"
```

**Problemas en microservicios:**
- **Bloqueos:** los tres servicios tienen recursos bloqueados hasta que el coordinador responde (puede ser segundos o minutos)
- **Disponibilidad:** si el coordinador cae en Fase 2, los participantes permanecen bloqueados indefinidamente
- **Acoplamiento:** todos los servicios deben hablar con el coordinador
- **Heterogeneidad:** no todos los DBs soportan 2PC (DynamoDB no lo soporta nativamente)

**Cuándo usar 2PC:** sistemas legados monolíticos con bases de datos que soportan XA transactions (Oracle, PostgreSQL). No usar en arquitecturas cloud-native.

---

## Saga — transacciones eventuales con compensaciones

Saga no bloquea: ejecuta cada paso y si algo falla, **compensa** lo ya hecho.

```
Paso 1: ReservarVuelo   → OK (vuelo AB123 reservado)
Paso 2: ReservarHotel   → OK (hab 204 reservada)
Paso 3: ReservarCoche   → FALLA (sin coches disponibles)

Compensación (orden inverso):
  CancelarHotel (hab 204) → OK
  CancelarVuelo (AB123)  → OK
Cliente notificado: reserva fallida
```

**Propiedades que garantiza Saga:**
- **Atomicidad eventual:** todos los pasos completan, o todos se compensan
- **Consistencia eventual:** el sistema llega a un estado consistente (no inmediatamente)
- **No hay aislamiento:** durante la saga, otros pueden ver el vuelo reservado pero el hotel no

**La ausencia de aislamiento es el trade-off clave.** Si otro cliente consulta la disponibilidad del hotel entre el paso 2 y la compensación, verá la habitación como ocupada temporalmente.

---

## Diseño de compensaciones

### Regla 1: Las compensaciones deben ser idempotentes

Si la compensación falla y se reintenta, el resultado debe ser el mismo:

```python
# MAL: decrementar contador (no idempotente)
UPDATE reservas SET plazas = plazas + 1 WHERE vuelo_id = 'AB123'
# Si se ejecuta dos veces: +2 plazas (incorrecto)

# BIEN: marcar como cancelada (idempotente)
UPDATE reservas SET status = 'cancelada' WHERE reserva_id = 'RES-001'
# Si se ejecuta dos veces: mismo resultado
```

### Regla 2: Diseñar para "compensación fallida"

¿Qué pasa si `CancelarVuelo` falla? Step Functions lo reintenta con backoff. Si sigue fallando:
- DLQ de la tarea de compensación
- Alerta a operaciones (SNS → PagerDuty)
- El estado en DynamoDB queda como `compensacion_fallida`
- Intervención manual o proceso de reconciliación nocturno

### Regla 3: Semantic rollback, no DB rollback

La compensación no deshace la transacción en la base de datos: **crea una nueva transacción inversa**. El historial queda completo:

```
reserva_id=RES-001  status=reservada   ts=10:00
reserva_id=RES-001  status=cancelada   ts=10:02  motivo=coche_no_disponible
```

Esto es correcto para auditoría. No borrar registros, marcarlos.

---

## Tabla comparativa

| Criterio | 2PC | Saga Orquestada | Saga Coreografiada |
|----------|-----|-----------------|-------------------|
| Consistencia | Fuerte | Eventual | Eventual |
| Disponibilidad | Baja (bloqueos) | Alta | Alta |
| Acoplamiento | Alto | Medio (conoce pasos) | Bajo |
| Debugging | Difícil | Fácil (SFN visual) | Muy difícil |
| Latencia | Alta (bloqueos) | Media | Baja |
| Compensaciones | Automático (abort) | Explícitas | Implícitas (eventos) |
| Cuándo usar | Legacy monolito | Transacciones complejas con auditoría | Workflows simples, alto throughput |
