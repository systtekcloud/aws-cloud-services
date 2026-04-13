# Lab 04: Seguridad en EKS

IRSA avanzado (condiciones múltiples, session tags), Secrets Store CSI Driver para secrets de AWS Secrets Manager, y Network Policies para aislar namespaces.

---

## Sub-labs

| Sub-lab | Contenido | Tiempo |
|---------|-----------|--------|
| [01-irsa-advanced](labs/01-irsa-advanced/) | Session tags, condiciones attribute_based, auditoría CloudTrail | 30 min |
| [02-secrets-csi](labs/02-secrets-csi/) | Secrets Store CSI Driver, montar secrets de Secrets Manager como ficheros | 35 min |
| [03-network-policies](labs/03-network-policies/) | Denegar tráfico por defecto, permitir selectivamente, validar con curl | 30 min |

---

## Conceptos clave

| Concepto | Resumen |
|----------|---------|
| IRSA session tags | Pasar metadata del pod como tags de sesión a CloudTrail |
| Secrets Store CSI | Montar secrets de AWS Secrets Manager como ficheros en el pod |
| External Secrets Operator | Sincronizar secrets de AWS a Kubernetes Secrets (alternativa) |
| NetworkPolicy | Reglas de ingress/egress por namespace/pod/IP |
| OPA Gatekeeper | Políticas de admission control (requiere imágenes con tag, no root) |

---

## Network Policies — Modelo mental

```
Sin NetworkPolicy: todos los pods pueden hablar entre sí (por defecto en K8s)

Con NetworkPolicy "deny-all" en namespace A:
  → ningún pod puede entrar a A
  → A puede añadir excepciones selectivas

Flujo correcto:
  1. Aplicar deny-all en todos los namespaces de producción
  2. Añadir políticas de allow explícitas para lo que sí se necesita
  3. Verificar con kubectl exec + curl

IMPORTANTE: NetworkPolicy requiere un CNI que lo soporte.
  - VPC CNI (EKS por defecto): NO soporta NetworkPolicy nativamente
  - Calico (addon): SÍ soporta NetworkPolicy
  - Cilium (addon): SÍ + eBPF para mejor rendimiento
```

---

## Recursos

- [labs/01-irsa-advanced/](labs/01-irsa-advanced/) — Session tags y auditoría
- [labs/02-secrets-csi/](labs/02-secrets-csi/) — Secrets Store CSI Driver
- [labs/03-network-policies/](labs/03-network-policies/) — Aislamiento de red
- [cleanup.md](cleanup.md)
