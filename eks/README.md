# Módulo EKS

Amazon Elastic Kubernetes Service — desde crear un cluster hasta GitOps con ArgoCD. Cada lab cubre un nivel diferente de la plataforma Kubernetes en AWS.

---

## Labs

| Lab | Contenido | Prereqs |
|-----|-----------|---------|
| [lab01-cluster](labs/lab01-cluster/) | Crear cluster EKS, IRSA, kubectl, Fargate vs Managed Nodes | networking/lab01-vpc |
| [lab02-workloads](labs/lab02-workloads/) | Deployments, Services, ALB Ingress Controller, Health checks | lab01 |
| [lab03-autoscaling](labs/lab03-autoscaling/) | HPA (CPU/custom metrics), Karpenter (node provisioning), KEDA | lab02 |
| [lab04-security](labs/lab04-security/) | IRSA avanzado, Secrets Store CSI, Network Policies, OPA Gatekeeper | lab03 |
| [lab05-observability](labs/lab05-observability/) | Container Insights, Fluent Bit → CloudWatch, X-Ray, Prometheus | lab04 |
| [lab06-gitops](labs/lab06-gitops/) | ArgoCD, App of Apps, GitOps workflow, progressive delivery | lab05 |

---

## Arquitectura del módulo

```
lab01: Cluster foundation
  EKS Control Plane + Fargate Profile + OIDC + IRSA

lab02: Workloads
  Deployments → Services → ALB Ingress

lab03: Scaling
  HPA (réplicas) + Karpenter (nodos) + KEDA (event-driven)

lab04: Security
  IRSA (permisos fine-grained) + CSI Secrets + NetworkPolicy

lab05: Observability
  Métricas → Logs → Traces (Container Insights + Fluent Bit + X-Ray)

lab06: GitOps
  ArgoCD → Git → Cluster (sync automático)
```

---

## Conceptos clave de EKS

| Concepto | Resumen |
|----------|---------|
| Control Plane | Gestionado por AWS ($0.10/hora). API Server, etcd, scheduler |
| Data Plane | Tus nodos: Managed Node Groups (EC2) o Fargate (serverless) |
| IRSA | IAM Roles for Service Accounts — permisos AWS fine-grained para pods |
| Fargate Profile | Define qué pods van a Fargate (sin gestionar EC2) |
| Add-ons | kube-proxy, CoreDNS, VPC CNI, EBS CSI — gestionados por AWS |
| eksctl | CLI oficial para gestionar clusters EKS |

---

## Fargate vs Managed Nodes

| Criterio | Fargate | Managed Node Groups |
|----------|---------|---------------------|
| Gestión | Sin EC2 que parchear | Patch automático pero tienes nodos |
| Escala | Inmediata por pod | Karpenter/CA (tarda 1-3 min) |
| Coste | vCPU+RAM por segundo | EC2 por hora (desperdicio si subutilizados) |
| Limitaciones | Sin DaemonSets, sin GPU, max 4vCPU/30GB | Sin límites |
| Ideal para | Cargas serverless, variable, sin estado | ML/GPU, DaemonSets, cost-optimized |

---

## Prerrequisitos

```bash
# Herramientas necesarias
aws --version          # AWS CLI v2
kubectl version        # kubectl 1.31+
eksctl version         # eksctl 0.180+
helm version           # Helm 3.x
```
