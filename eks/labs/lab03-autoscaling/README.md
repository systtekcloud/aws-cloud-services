# Lab 03: Autoscaling en EKS

HPA para escalar pods por CPU/métricas custom, Karpenter para provisionar nodos eficientemente, y KEDA para escalar basado en eventos externos (SQS, Kinesis, etc.).

---

## Sub-labs

| Sub-lab | Contenido | Tiempo |
|---------|-----------|--------|
| [01-hpa](labs/01-hpa/) | HPA con CPU target, metrics-server, load test | 30 min |
| [02-karpenter](labs/02-karpenter/) | Instalar Karpenter, NodePool, interruption handling | 40 min |
| [03-keda](labs/03-keda/) | KEDA con ScaledObject sobre SQS, scale-to-zero | 35 min |

---

## Comparativa de escaladores

| Herramienta | Qué escala | Basado en | Cuándo usar |
|-------------|-----------|-----------|-------------|
| HPA | Pods (réplicas) | CPU, memoria, métricas Prometheus/custom | Cargas HTTP predecibles |
| VPA | Recursos de pods | CPU/memoria históricos | Ajustar requests/limits |
| Karpenter | Nodos | Pods pendientes (unschedulable) | Node provisioning eficiente |
| KEDA | Pods | Eventos externos (SQS, Kafka, Kinesis) | Cargas event-driven |

**En la práctica:** HPA + Karpenter es la combinación más común. KEDA para casos específicos event-driven.

---

## Concept Map

### HPA

```
HPA Controller (corre en control plane, cada 15s)
  │ consulta metrics-server (CPU/mem) o custom metrics
  ▼
Calcula réplicas deseadas:
  deseadas = ceil(actuales × (métrica_actual / objetivo))
  Ej: 3 pods, CPU 80%, objetivo 50% → ceil(3 × 80/50) = ceil(4.8) = 5 pods
  ▼
Actualiza Deployment.spec.replicas
  │ Scale-up: inmediato
  │ Scale-down: espera 5 minutos por defecto (evitar flapping)
```

### Karpenter

```
Pod en estado Pending (no hay nodo con recursos suficientes)
  ↓
Karpenter detecta el pod en <30s
  ↓
Elige el tipo de instancia más eficiente (precio/recursos)
  → Considera: requirements del pod (nodeSelector, affinity)
  → Considera: Spot vs On-Demand (consolidation)
  ↓
Lanza instancia EC2 directamente (sin Node Groups)
  ↓
Pod scheduled en <2 min (vs 3-5 min con Cluster Autoscaler)
  ↓
Karpenter Consolidation: cuando nodo subutilizado >30min
  → mueve pods a otros nodos y termina el nodo vacío
```

### KEDA

```
SQS Queue (100 mensajes pendientes)
  │
KEDA ScaledObject (cada 30s comprueba métricas)
  │ desiredReplicas = queueLength / targetQueueLength
  │ Ej: 100 msgs / 10 msgs_por_pod = 10 pods
  ▼
KEDA crea/actualiza HPA con métricas externas
  ▼
HPA escala el Deployment a 10 pods
  ▼
Cuando cola vacía → scale to zero (0 pods)
  → KEDA es el único que puede escalar a 0
```

---

## Recursos

- [labs/01-hpa/](labs/01-hpa/) — HPA con metrics-server y load test
- [labs/02-karpenter/](labs/02-karpenter/) — Karpenter NodePool y consolidation
- [labs/03-keda/](labs/03-keda/) — KEDA ScaledObject con SQS
- [cleanup.md](cleanup.md)
