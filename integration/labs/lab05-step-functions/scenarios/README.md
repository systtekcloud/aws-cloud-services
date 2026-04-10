# Lab 05 — Scenarios: Step Functions en decisiones de arquitectura

## Scenario 1: Step Functions vs SQS+Lambda para workflows

**Caso: pipeline de onboarding de usuario** (5 pasos: verificar email → crear perfil → enviar bienvenida → activar cuenta → notificar CRM)

```
Opción A: SQS+Lambda encadenadas
  Lambda A → SQS → Lambda B → SQS → Lambda C → ...
  + Sin coste adicional por transición
  - Estado del workflow disperso (¿en qué paso está el usuario?)
  - Debugging requiere correlacionar logs de 5 funciones
  - Retry de un paso puede ejecutar pasos anteriores
  - Rollback imposible sin código personalizado

Opción B: Step Functions Standard
  + Historial visual completo en consola
  + Retry declarativo por estado
  + Estado del workflow siempre visible
  + Rollback via compensaciones (Saga)
  - $0.025 por 1.000 transiciones (para 1M usuarios/mes: $125)
```

**Regla:** si el debugging y la auditoría son importantes, el coste de Step Functions se justifica. Para pipelines de alta frecuencia (>100K/min) y simples → SQS+Lambda.

---

## Scenario 2: Standard vs Express — cuándo cada uno

| Necesidad | Tipo | Por qué |
|-----------|------|---------|
| Proceso de pedido (auditoria obligatoria) | Standard | Historial 90 días, exactly-once |
| Transcodificación de video (long running) | Standard | Duración > 5 min |
| Validación de eventos IoT (100K/s) | Express | Throughput, coste |
| Microservicio orquestado de corta duración | Express | Barato, alta frecuencia |
| Saga con compensaciones | Standard | Estado necesario entre pasos |
| ETL batch con Distributed Map | Standard | Larga duración |

**Trampa:** Express no tiene historial en consola. Si un Express falla, solo puedes investigarlo en CloudWatch Logs. Configura siempre `level: ALL` en logging.

---

## Scenario 3: Saga vs Two-Phase Commit para microservicios

```
Sistema bancario: transferencia entre 2 cuentas en bancos distintos

2-Phase Commit:
  Fase 1: bloquear fondos en banco A y banco B → esperar confirmación
  Fase 2: si ambos confirman → COMMIT, si alguno falla → ROLLBACK
  Problema: banco B puede estar caído durante horas → fondos bloqueados horas

Saga:
  Paso 1: debitar banco A → si falla → fin (no hay compensación necesaria)
  Paso 2: acreditar banco B → si falla → compensación: devolver fondos a banco A
  Ventaja: banco A y banco B son independientes, sin locks distribuidos
  Riesgo: hay un momento (~ms) donde el dinero salió de A pero no llegó a B
           → consistencia eventual, no fuerte
```

**Para sistemas financieros reales:** saga + registro de auditoría en DynamoDB + idempotency tokens. La consistencia eventual es aceptable si el tiempo de convergencia es <1s.

---

## Scenario 4: Distributed Map vs EMR para batch processing

| Caso | Distributed Map | EMR (Spark/Hive) |
|------|-----------------|------------------|
| Miles de ficheros pequeños (<1MB) | ✓ Ideal | Overhead excesivo |
| Fichero de 1TB | ✗ No aplica | ✓ Ideal |
| Sin DevOps de Spark | ✓ Solo Lambda | ✗ Necesitas expertise Spark |
| Coste para 10K invocaciones Lambda | ~$0.02 | ~$2 (cluster mínimo 10 min) |
| Transformación compleja con joins | ✗ Difícil | ✓ SQL nativo |
| Time to market | ✓ Rápido | ✗ Configuración cluster |

**Regla:** Distributed Map para fan-out de procesamiento independiente por item. EMR cuando necesitas joins, agregaciones o el volumen de datos supera lo manejable en memoria Lambda.
