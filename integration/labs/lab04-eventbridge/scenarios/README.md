# Lab 04 — Scenarios: EventBridge en decisiones de arquitectura

## Scenario 1: Default Bus vs Custom Bus

**Default bus:** recibe eventos de AWS automáticamente. Útil para reaccionar a cambios de infraestructura:
- EC2 instance state change → notificar al equipo
- RDS failover → invalidar cache
- ECS task stopped → alerta si exit code != 0
- Config rule non-compliant → ticket automático

**Custom bus:** para eventos de tu aplicación. Ventajas sobre default bus:
- Aislamiento (tus eventos no mezclan con eventos AWS)
- Resource policy para cross-account
- Schema discovery separado

**Regla:** default bus para automatización de ops. Custom bus para eventos de negocio.

## Scenario 2: EventBridge Scheduler — reemplaza cron jobs

```bash
# Cron job tradicional: necesitas EC2/Lambda siempre activa
# EventBridge Scheduler: invoca Lambda/Step Functions/etc. en horario

aws scheduler create-schedule \
  --name "informe-diario" \
  --schedule-expression "cron(0 8 * * ? *)" \
  --target '{
    "Arn": "arn:aws:lambda:...:function:generar-informe",
    "RoleArn": "arn:aws:iam::...:role/scheduler-role"
  }' \
  --flexible-time-window '{"Mode": "OFF"}'
```

Soporta one-time schedules también (`at(2026-12-31T23:59:00)`).

## Scenario 3: Event Archive y Replay

```bash
# Archivar todos los eventos del custom bus
aws events create-archive \
  --archive-name lab04-archive \
  --event-source-arn "$BUS_ARN" \
  --retention-days 30

# Replay: reenviar eventos de un rango de tiempo al bus
# Útil para: recuperación ante fallos, testing, debugging
aws events start-replay \
  --replay-name replay-bug-investigation \
  --event-source-arn "arn:aws:events:...:archive/lab04-archive" \
  --event-start-time "2026-04-01T00:00:00" \
  --event-end-time   "2026-04-01T12:00:00" \
  --destination '{"Arn": "$BUS_ARN"}'
```

## Scenario 4: EventBridge Pipes vs Lambda glue

```
Caso: DynamoDB Stream → procesar solo INSERTs → enviar a Step Functions

Sin Pipes:
  DDB Stream → Lambda (solo filtra y reenvía) → Step Functions
  Coste: Lambda cobrada por cada registro, aunque no haga nada útil

Con Pipes:
  DDB Stream → [Filter: eventName=INSERT] → Step Functions
  Coste: solo los registros que pasan el filtro, sin Lambda intermedia

Ahorro típico: 60-80% menos coste en pipelines de filtrado puro.
```
