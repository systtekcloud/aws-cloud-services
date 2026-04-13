# Lab 05: Observabilidad en EKS

Container Insights para métricas del cluster, Fluent Bit para logs estructurados a CloudWatch, y X-Ray para distributed tracing entre microservicios.

---

## Los tres pilares

```
Métricas → Container Insights (CPU, memoria, red, disco por pod/node/namespace)
            ↓ CloudWatch Metrics + CloudWatch Dashboard

Logs     → Fluent Bit DaemonSet (un agente por nodo)
            ↓ CloudWatch Logs (un log group por namespace)

Trazas   → X-Ray SDK en la app + X-Ray Daemon sidecar
            ↓ X-Ray Service Map (visualiza latencia entre servicios)
```

---

## Sub-labs

| Sub-lab | Contenido | Tiempo |
|---------|-----------|--------|
| [01-container-insights](labs/01-container-insights/) | Habilitar Container Insights, dashboards, alarmas | 25 min |
| [02-fluent-bit](labs/02-fluent-bit/) | Fluent Bit DaemonSet, filtros, log groups por namespace | 30 min |
| [03-xray](labs/03-xray/) | X-Ray Daemon sidecar, SDK en Python, Service Map | 35 min |

---

## Arquitectura de observabilidad

```
EKS Cluster
  │
  ├─ Container Insights (add-on EKS)
  │   └─ CloudWatch Agent DaemonSet → CloudWatch Metrics
  │       └─ Dashboard: CPU/mem por pod, node, namespace
  │
  ├─ Fluent Bit DaemonSet
  │   └─ Lee /var/log/containers/*.log
  │   └─ Parsea JSON, añade metadata (namespace, pod, container)
  │   └─ Envía a CloudWatch Logs: /aws/eks/{cluster}/{namespace}
  │
  └─ X-Ray Daemon (sidecar por pod)
      └─ Recibe UDP :2000 del SDK
      └─ Envía trazas al servicio X-Ray
          └─ X-Ray Service Map
          └─ X-Ray Traces (drill-down por request)
```

---

## Recursos

- [labs/01-container-insights/](labs/01-container-insights/)
- [labs/02-fluent-bit/](labs/02-fluent-bit/)
- [labs/03-xray/](labs/03-xray/)
- [cleanup.md](cleanup.md)
