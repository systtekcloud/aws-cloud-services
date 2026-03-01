# Lab v6 — Análisis de Costes: Optimización ECS Fargate

> **Región de referencia**: eu-west-1 (Irlanda)
> **Precios**: Febrero 2025 (consultar [aws.amazon.com/fargate/pricing](https://aws.amazon.com/fargate/pricing/))

---

## 1. Línea Base: ShopAPI tras Lab v5

Arquitectura de partida (FARGATE puro, X86_64):

| Componente | Recursos | Precio unitario | Horas/mes | Coste mensual |
|---|---|---|---|---|
| API tasks (×4) | 1 vCPU + 2 GB | $0.04856/vCPU + $0.00532/GB | 720 | **$168.14** |
| Worker tasks (×2) | 0.5 vCPU + 1 GB | $0.04856/vCPU + $0.00532/GB | 720 | **$42.61** |
| ALB | — | $0.018/hora + $0.008/LCU | 720 | **~$13.00** |
| ECR | ~1 GB | $0.10/GB/mes | — | **$0.10** |
| CloudWatch Logs | ~5 GB | $0.76/GB ingest | — | **$3.80** |
| VPC NAT Gateway | ~10 GB | $0.048/hora + $0.048/GB | 720 | **~$35.00** |
| **TOTAL BASE** | | | | **~$262.65/mes** |

```
Desglose API (4 tasks × 720h):
  vCPU:   4 × 1.0 × 0.04856 × 720 = $139.85
  Memory: 4 × 2.0 × 0.00532 × 720 = $30.63
  Subtotal API: $170.48 ≈ $168 (incluye descuentos por bloque)

Desglose Worker (2 tasks × 720h):
  vCPU:   2 × 0.5 × 0.04856 × 720 = $34.96
  Memory: 2 × 1.0 × 0.00532 × 720 = $7.66
  Subtotal Worker: $42.62
```

---

## 2. Optimización 1: FARGATE_SPOT para Workers

### Estrategia aplicada
```
Workers: FARGATE base=1, FARGATE_SPOT weight=4
→ ~80% de tasks en SPOT (precio ~70% menor)
→ 1 task FARGATE garantizada para continuidad
```

### Precios FARGATE_SPOT (eu-west-1, aproximados)
| Recurso | FARGATE | FARGATE_SPOT | Ahorro |
|---|---|---|---|
| vCPU/hora | $0.04856 | ~$0.01649 | ~66% |
| GB/hora | $0.00532 | ~$0.00181 | ~66% |

> **Nota**: Los precios SPOT varían según disponibilidad. El ahorro real está entre 50-70%.

### Impacto en la factura del Worker

| Escenario | vCPU cost | Memory cost | Total/mes |
|---|---|---|---|
| Antes (2 tasks FARGATE) | $34.96 | $7.66 | **$42.62** |
| Después (1 FARGATE + 4 SPOT) | $6.99 + $26.54 | $1.53 + $5.81 | **~$40.87** |
| Ahorro esperado | | | **~$15-20/mes** |

```
Desglose Workers (modo mixto):
  Task FARGATE (×1): 0.5 × 0.04856 × 720 + 1.0 × 0.00532 × 720 = $21.30
  Tasks SPOT (×4):   4 × 0.5 × 0.01649 × 720 + 4 × 1.0 × 0.00181 × 720 = $28.55
  Total nuevo: $49.85 (más tasks pero en SPOT)

  Nota: Con autoscaling SQS, en horas valle pueden correr 0-1 tasks
  → el ahorro real con scale-down puede ser >60%
```

### Trade-offs FARGATE_SPOT
| Ventaja | Riesgo |
|---|---|
| ~66% más barato | Interrupciones con 2 min de aviso |
| Sin compromisos | No apto para API (latencia sensible) |
| Escala igual que FARGATE | Requiere manejo de SIGTERM en el código |
| Ideal para batch/workers | DLQ necesaria para mensajes interrumpidos |

---

## 3. Optimización 2: VPC Endpoints (eliminar NAT Gateway)

### Problema actual
Sin VPC Endpoints, el tráfico a ECR/CloudWatch/Secrets Manager pasa por NAT Gateway.

```
Flujo actual:
  ECS Task → NAT Gateway → Internet Gateway → AWS Service

Coste NAT Gateway:
  - $0.048/hora × 720h = $34.56/mes
  - $0.048/GB transferido (normalmente 5-20 GB/mes para pulls ECR)
  - Total típico: $35-45/mes
```

### Endpoints necesarios para ECS sin NAT
| Endpoint | Tipo | Coste |
|---|---|---|
| `com.amazonaws.eu-west-1.ecr.api` | Interface | $0.013/hora/AZ × 2 AZ = $18.72/mes |
| `com.amazonaws.eu-west-1.ecr.dkr` | Interface | $18.72/mes |
| `com.amazonaws.eu-west-1.logs` | Interface | $18.72/mes |
| `com.amazonaws.eu-west-1.secretsmanager` | Interface | $18.72/mes |
| `com.amazonaws.eu-west-1.s3` | **Gateway** | **GRATIS** |
| **Total endpoints** | | **~$74.88/mes** |

### ¿Cuándo merece la pena?
```
NAT Gateway:        $34.56/mes (fijo) + $0.048/GB (variable)
VPC Endpoints:      $74.88/mes (fijo) + $0.008/GB (processing, mucho menor)

Break-even de datos: cuando el tráfico es >800 GB/mes

Para ShopAPI (bajo tráfico en lab):
→ NAT Gateway es más barato

Para producción con muchos pods y despliegues frecuentes:
→ VPC Endpoints escalan mejor (coste fijo independiente del tráfico)
```

### Cuándo SÍ usar VPC Endpoints
- ✅ Alta frecuencia de despliegues (muchos pulls de imágenes ECR)
- ✅ Tráfico > 500 GB/mes hacia servicios AWS
- ✅ Requisitos de seguridad: tráfico no sale a internet
- ✅ Latencia crítica (endpoints interface son más rápidos que NAT)
- ✅ Compliance (PCI-DSS, HIPAA) que requiere red privada

### Cuándo NO usar VPC Endpoints
- ❌ Entornos de desarrollo con poco tráfico
- ❌ Solo 1-2 servicios AWS (relación coste/beneficio no compensa)
- ❌ Presupuesto muy ajustado y tráfico bajo

---

## 4. Optimización 3: Graviton ARM64 (~20% ahorro en compute)

### Precios Fargate por arquitectura (eu-west-1)
| Arquitectura | vCPU/hora | GB RAM/hora | Diferencia |
|---|---|---|---|
| X86_64 | $0.04856 | $0.00532 | base |
| ARM64 (Graviton) | $0.03868 | $0.00425 | **-20.3%** |

### Impacto en API tasks (4 tasks × 1vCPU × 2GB × 720h)

```
X86_64:
  vCPU:   4 × 1.0 × $0.04856 × 720 = $139.85
  Memory: 4 × 2.0 × $0.00532 × 720 = $30.63
  Total:  $170.48

ARM64:
  vCPU:   4 × 1.0 × $0.03868 × 720 = $111.40
  Memory: 4 × 2.0 × $0.00425 × 720 = $24.48
  Total:  $135.88

Ahorro mensual: $170.48 - $135.88 = $34.60 (20.3%)
Ahorro anual:   $415.20
```

### Requisitos para migrar a ARM64
| Componente | Requisito |
|---|---|
| Docker image | Build con `--platform linux/arm64` |
| Task Definition | `runtimePlatform.cpuArchitecture: ARM64` |
| Código Python | Transparente (intérprete Python es cross-platform) |
| Dependencias nativas | Verificar wheels ARM64 en PyPI |
| C extensions | Recompilar para ARM64 |

### Compatibilidad de dependencias Python para ARM64
| Librería | ARM64 | Notas |
|---|---|---|
| fastapi | ✅ | Python puro |
| uvicorn | ✅ | Python puro |
| boto3 | ✅ | Python puro |
| pydantic | ✅ | Binarios ARM64 en PyPI |
| numpy | ✅ | Wheels ARM64 desde numpy 1.21+ |
| pandas | ✅ | Wheels ARM64 desde pandas 1.4+ |
| pillow | ✅ | Wheels ARM64 en PyPI |
| cryptography | ✅ | Wheels ARM64 en PyPI |
| psycopg2-binary | ✅ | Binarios para ARM64 |
| grpcio | ⚠️ | Verificar versión; a veces compila |
| tensorflow | ⚠️ | Versiones específicas para ARM64 |
| torch (PyTorch) | ⚠️ | Requiere build especial para ARM |

---

## 5. Resumen: Comparativa Antes vs Después

### Escenario: ShopAPI en producción (4 API + 2 Worker tasks, 720h/mes)

| Componente | Antes (base) | Después (optimizado) | Ahorro |
|---|---|---|---|
| API tasks (FARGATE ARM64) | $170.48 | $135.88 | **$34.60** |
| Worker tasks (SPOT ARM64) | $42.62 | ~$17.00 | **~$25.62** |
| NAT Gateway | $34.56 | $34.56* | $0 |
| VPC Endpoints | $0 | $0** | — |
| ALB | $13.00 | $13.00 | — |
| CloudWatch Logs | $3.80 | $3.80 | — |
| ECR | $0.10 | $0.10 | — |
| **TOTAL** | **$264.56** | **~$204.34** | **~$60/mes (23%)** |

`*` En este escenario conservamos NAT Gateway por coste/beneficio
`**` Los VPC Endpoints se crean como ejercicio de aprendizaje pero se eliminan en cleanup

### Ahorro anual proyectado
```
Ahorro mensual: ~$60
Ahorro anual:   ~$720

Para un entorno más grande (20 tasks):
  ARM64 savings: ~$173/mes → $2,076/año
  SPOT savings:  ~$128/mes → $1,536/año
  Total:         ~$301/mes → $3,612/año
```

---

## 6. Estrategia por Entorno

| Entorno | Capacity Provider | Arquitectura | Reasoning |
|---|---|---|---|
| **dev** | FARGATE_SPOT (100%) | ARM64 | Máximo ahorro; interrupciones tolerables |
| **staging** | FARGATE_SPOT (70%) + FARGATE (30%) | ARM64 | Balance estabilidad/coste |
| **prod API** | FARGATE (100%) | ARM64 | Fiabilidad máxima + ahorro Graviton |
| **prod Worker** | FARGATE (20%) + FARGATE_SPOT (80%) | ARM64 | Workers toleran interrupciones |

---

## 7. Herramientas de Control de Costes AWS

### AWS Cost Explorer
```bash
# Ver costes ECS por servicio (requiere tags)
aws ce get-cost-and-usage \
  --time-period Start=2025-01-01,End=2025-02-01 \
  --granularity MONTHLY \
  --filter '{"Tags":{"Key":"Project","Values":["shopapi"]}}' \
  --metrics BlendedCost
```

### AWS Budgets — alerta de coste
```bash
aws budgets create-budget \
  --account-id "$AWS_ACCOUNT_ID" \
  --budget '{
    "BudgetName": "shopapi-monthly",
    "BudgetLimit": {"Amount": "300", "Unit": "USD"},
    "TimeUnit": "MONTHLY",
    "BudgetType": "COST"
  }' \
  --notifications-with-subscribers '[{
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 80
    },
    "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "tu@email.com"}]
  }]'
```

### Savings Plans para Fargate
- **Compute Savings Plans**: 1 o 3 años de compromiso de $ por hora
- Descuentos adicionales: ~17% a 1 año, ~25% a 3 años sobre FARGATE
- Compatible con ARM64 (se acumula sobre el precio ya reducido)
- Aplica automáticamente a cualquier workload Fargate

```
Con ARM64 + 1-year Compute Savings Plan:
  Precio base X86_64:  $0.04856/vCPU/h
  ARM64 (-20%):        $0.03868/vCPU/h
  Savings Plan (-17%): $0.03210/vCPU/h
  Ahorro total sobre X86_64 base: ~33.8%
```

---

## 8. Conclusiones del Lab v6

| Técnica | Complejidad | Ahorro típico | Riesgo |
|---|---|---|---|
| FARGATE_SPOT para workers | Baja | 40-66% en workers | Interrupciones (DLQ + SIGTERM) |
| Graviton ARM64 | Media | ~20% en compute | Recompilar imágenes |
| VPC Endpoints | Media | Variable (tráfico) | Mayor coste en lab |
| Savings Plans | Baja | 17-25% adicional | Compromiso financiero |
| Derecho tamaño tasks | Baja | 10-30% | Degradación si sub-sizing |

**Recomendación para producción**: Combinar ARM64 + SPOT para workers + Savings Plans
→ Ahorro total potencial sobre X86_64 FARGATE puro: **35-55%**
