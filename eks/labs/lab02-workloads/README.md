# Lab 02: Workloads en EKS

Deployments, Services, Ingress con AWS ALB Ingress Controller, health checks, y gestión del ciclo de vida de aplicaciones en Kubernetes.

---

## Sub-labs

| Sub-lab | Contenido | Tiempo |
|---------|-----------|--------|
| [01-deployments-services](labs/01-deployments-services/) | Deployment, ReplicaSet, rolling update, Services (ClusterIP/NodePort/LoadBalancer) | 45 min |
| [02-alb-ingress](labs/02-alb-ingress/) | Instalar ALB Ingress Controller, reglas de routing por path y host, HTTPS | 40 min |

---

## Conceptos clave

| Concepto | Resumen |
|----------|---------|
| Deployment | Gestiona ReplicaSets → garantiza N réplicas del pod |
| ReplicaSet | Mantiene N pods en ejecución |
| Rolling Update | Actualiza pods gradualmente (maxUnavailable, maxSurge) |
| Service ClusterIP | IP virtual interna del cluster (L4) |
| Service NodePort | Expone en un puerto del nodo (30000-32767) |
| Service LoadBalancer | Crea un ELB (CLB/NLB) en AWS |
| Ingress | Routing L7 (HTTP/HTTPS) via ALB Ingress Controller |
| ALB Ingress Controller | Crea y gestiona ALBs automáticamente en respuesta a recursos Ingress |
| Liveness Probe | Si falla: restart del pod |
| Readiness Probe | Si falla: pod removido del Service (sin tráfico) |

---

## Terraform quickstart

```bash
cd terraform/
terraform init && terraform apply

# Instalar ALB Ingress Controller
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=eks-dev \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform output -raw alb_controller_role_arn)
```

---

## Recursos

- [concept-map/](concept-map/) — Deployment lifecycle, Service types, Ingress routing, health probes
- [labs/01-deployments-services/](labs/01-deployments-services/) — Deploy app, rolling update, Services
- [labs/02-alb-ingress/](labs/02-alb-ingress/) — ALB Ingress Controller, multi-path routing, HTTPS
- [manifests/](manifests/) — YAML de referencia para todos los recursos
- [cleanup.md](cleanup.md)
