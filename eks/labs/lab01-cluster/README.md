# Lab 01: Crear un cluster EKS

Aprende a crear un cluster EKS desde cero, configurar kubectl, entender el modelo de nodos (Fargate vs Managed Nodes), y configurar IRSA para que los pods tengan permisos AWS sin credenciales en el código.

---

## Sub-labs

| Sub-lab | Contenido | Tiempo |
|---------|-----------|--------|
| [01-create-cluster](labs/01-create-cluster/) | eksctl, kubeconfig, primeros pods en Fargate | 45 min |
| [02-irsa](labs/02-irsa/) | OIDC provider, IAM role para ServiceAccount, demo con S3 | 30 min |

---

## Conceptos clave

| Concepto | Resumen |
|----------|---------|
| Control Plane | AWS lo gestiona: API Server, etcd, scheduler ($0.10/hora) |
| Fargate Profile | Selector namespace/labels → pods van a Fargate automáticamente |
| OIDC Provider | Permite que EKS valide tokens de ServiceAccounts con IAM |
| IRSA | El pod asume un rol IAM via OIDC — sin credenciales en el código |
| kubeconfig | Fichero ~/.kube/config con credenciales del cluster |
| eksctl | CLI de Weaveworks para crear/gestionar clusters EKS |

---

## Terraform quickstart

```bash
cd terraform/
terraform init && terraform apply -var="environment=dev"

# Configurar kubectl
aws eks update-kubeconfig --name eks-dev --region eu-west-1

# Verificar
kubectl get nodes      # Fargate nodes aparecen como "Ready"
kubectl get namespaces
```

---

## Recursos

- [concept-map/](concept-map/) — EKS architecture, control plane vs data plane, Fargate vs Managed Nodes, IRSA flow
- [labs/01-create-cluster/](labs/01-create-cluster/) — Crear cluster con eksctl, kubectl config, primeros pods
- [labs/02-irsa/](labs/02-irsa/) — OIDC provider, IAM roles para pods
- [terraform/](terraform/) — EKS cluster + Fargate profiles + IRSA
- [scenarios/](scenarios/) — Managed Nodes vs Fargate decision tree, cluster upgrade
- [cleanup.md](cleanup.md) — Borrar cluster y recursos
