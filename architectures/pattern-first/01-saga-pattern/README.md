# Saga Pattern — Transacciones distribuidas orquestadas

**Tipo:** Pattern-First  
**Patrón:** Saga orquestada para transacciones distribuidas entre microservicios independientes sin transacción ACID global.

**Caso de uso:** Reserva de viaje (vuelo + hotel + coche). Si cualquier paso falla, deshacer todo lo anterior en orden inverso.

---

## El problema que resuelve

En un monolito, una transacción de reserva es atómica:
```sql
BEGIN;
  INSERT INTO vuelos ...
  INSERT INTO hoteles ...
  INSERT INTO coches ...
COMMIT; -- o ROLLBACK todo
```

Con microservicios independientes (cada uno con su propia base de datos), no hay `COMMIT` global. Si el hotel falla después de reservar el vuelo, ¿quién cancela el vuelo?

La Saga divide la transacción en pasos locales con **compensaciones** (cancelaciones) en caso de fallo.

---

## Arquitectura

```
Cliente
  │
  ▼ POST /reservas
API Gateway
  │
  ▼
Step Functions (orquestador Saga)
  │
  ├─ ReservarVuelo (Lambda → SQS vuelos → ECS servicio-vuelos)
  │       │ éxito → siguiente paso
  │       └ fallo → CancelarVuelo (compensación)
  │
  ├─ ReservarHotel (Lambda → SQS hoteles → ECS servicio-hoteles)
  │       │ éxito → siguiente paso
  │       └ fallo → CancelarHotel + CancelarVuelo
  │
  ├─ ReservarCoche (Lambda → SQS coches → ECS servicio-coches)
  │       │ éxito → saga completa
  │       └ fallo → CancelarCoche + CancelarHotel + CancelarVuelo
  │
  └─ NotificarCliente (SNS → email confirmación)

DynamoDB: estado de cada saga + historial de compensaciones
```

---

## Por qué Step Functions como orquestador

**Saga orquestada (Step Functions):**
- Un componente central conoce el estado completo
- Si falla el orquestador: Step Functions persiste el estado, continúa desde donde estaba
- Debugging: visibilidad completa del flujo en consola
- Compensaciones explícitas en el ASL (Amazon States Language)

**Saga coreografiada (EventBridge):**
- Cada servicio reacciona a eventos y emite nuevos eventos
- Sin coordinador central → más desacoplado
- Pero: si hay un fallo a mitad, ¿quién sabe qué compensar?
- Debugging: correlacionar eventos de 5 servicios distintos es difícil

Para transacciones financieras o con auditoría: **orquestada** siempre.

---

## Módulos Terraform

| Módulo | Recursos | Descripción |
|--------|----------|-------------|
| [modules/orchestrator/](modules/orchestrator/) | Step Functions + IAM | Lógica de la saga |
| [modules/services/](modules/services/) | 3 × (SQS + Lambda mock) | Servicios de reserva simulados |
| [modules/state/](modules/state/) | DynamoDB + SNS | Estado y notificaciones |

## Entornos

```bash
cd dev/ && terragrunt apply   # Lambda mocks, sin ECS real
cd prod/ && terragrunt apply  # ECS Fargate reales vía SQS
```

---

## Recursos relacionados

- [design/saga-vs-2pc.md](design/saga-vs-2pc.md) — Saga vs Two-Phase Commit
- [design/compensation-patterns.md](design/compensation-patterns.md) — Diseño de compensaciones idempotentes
- [scenarios/](scenarios/) — Saga parcialmente completada, timeout, compensación fallida
