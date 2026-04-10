# Opciones de diseño consideradas

## Opción A: Arquitectura propuesta (elegida)

```
API GW → SQS FIFO → Lambda → Step Functions → DynamoDB → SNS
```

**✓ Pros:**
- Exactly-once garantizado (SQS FIFO + DynamoDB condition)
- Auditoría completa en Step Functions (historial por ejecución)
- Desacoplado: la API responde 202, el backend procesa sin presión
- Retry declarativo sin código adicional
- DynamoDB escala automáticamente

**✗ Contras:**
- Latencia percibida: el cliente no sabe el resultado inmediatamente
- Complejidad: 5 servicios coordinados
- Coste Step Functions: $0.025/1K transiciones (para 1M pagos/mes ≈ $125)

---

## Opción B: ECS synchronous con RDS Aurora

```
API GW → ECS Fargate (servicio de pagos) → RDS Aurora → SES (email)
```

**✓ Pros:**
- Respuesta síncrona: el cliente sabe el resultado inmediatamente (200 OK o error)
- Lógica centralizada en el servicio (más fácil de depurar)
- SQL para queries de auditoría complejas

**✗ Contras:**
- Connection pool: ECS necesita gestionar conexiones a RDS (PgBouncer/RDS Proxy)
- Escalado acoplado: si el banco externo es lento, el servicio de pagos se satura
- RDS Aurora Serverless v2: mínimo $0.12/hora aunque esté idle
- No hay retry automático si el banco falla — hay que implementarlo
- Disponibilidad limitada por RDS (aunque Aurora es 99.99%)

**Cuándo elegir B:** sistema legacy con mucho SQL ya escrito, equipo sin experiencia serverless, necesidad de respuesta síncrona 100%.

---

## Opción C: Coreografía con EventBridge (sin orquestador)

```
API GW → Lambda (valida) → EventBridge → [Lambda banco] → EventBridge → [Lambda DynamoDB] → ...
```

**✓ Pros:**
- Desacoplado: cada Lambda es independiente
- Sin coste de Step Functions
- Fácil añadir nuevos pasos (nueva Lambda suscrita a EventBridge)

**✗ Contras:**
- **Sin visibilidad del flujo completo:** si un pago falla a mitad, ¿en qué paso está?
- Debugging: correlacionar logs de 5 Lambdas distintas con el mismo pago_id
- Exactly-once es responsabilidad de cada Lambda (idempotency manual)
- No hay retry declarativo — cada Lambda gestiona sus propios reintentos
- Auditoría: hay que construirla explícitamente (registro en DynamoDB en cada Lambda)

**Cuándo elegir C:** el flujo es simple (2-3 pasos), la auditoría no es crítica, el throughput es muy alto (Express Workflows de Step Functions no llega a 100K ejecuciones/segundo).

---

## Tabla comparativa

| Criterio | A (elegida) | B (ECS+RDS) | C (coreografía) |
|----------|-------------|-------------|-----------------|
| Exactly-once | ✓ nativo | Manual (idempotency) | Manual |
| Auditoría | ✓ nativa (SFN) | Manual (SQL) | Manual (DynamoDB) |
| Visibilidad del flujo | ✓ visual | Logs | Difícil |
| Latencia percibida | Asíncrona (202) | Síncrona (<2s) | Asíncrona |
| Coste ~1M pagos/mes | ~$200 | ~$300 | ~$50 |
| Complejidad operacional | Media | Alta (RDS+pool) | Alta (debugging) |
| Time to market | Medio | Alto | Medio |
| SLA facilidad | Alta (SQS buffer) | Media | Media |

**Decisión:** Opción A para este caso (fintech, auditoría legal obligatoria, equipo con experiencia serverless). Opción B si el equipo es backend tradicional y necesita SQL. Opción C solo para volúmenes extremos donde el coste de Step Functions es prohibitivo.
