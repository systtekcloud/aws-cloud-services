# Sub-lab 01: Instalar ArgoCD y crear la primera Application

## Objetivo

Instalar ArgoCD via Helm, acceder al dashboard, y desplegar una aplicación desde un repositorio Git público.

---

## Paso 1: Instalar ArgoCD

```bash
# Crear namespace
kubectl create namespace argocd

# Instalar via Helm
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd \
  --namespace argocd \
  --version 6.7.11 \
  --set server.extraArgs="{--insecure}" \  # HTTP para el lab (en prod: TLS + Ingress HTTPS)
  --set configs.params."server\.insecure"=true

# Verificar que todos los pods están Running (~3 min)
kubectl wait pods --namespace argocd \
  --for=condition=Ready \
  --selector=app.kubernetes.io/name=argocd-server \
  --timeout=120s

kubectl get pods -n argocd
# NAME                                 READY   STATUS    RESTARTS
# argocd-application-controller-xxx   1/1     Running   0
# argocd-dex-server-xxx               1/1     Running   0
# argocd-redis-xxx                     1/1     Running   0
# argocd-repo-server-xxx              1/1     Running   0
# argocd-server-xxx                   1/1     Running   0
```

## Paso 2: Acceder al dashboard

```bash
# Port-forward al API server de ArgoCD
kubectl port-forward svc/argocd-server -n argocd 8080:80 &

# Obtener la contraseña inicial del admin
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo "Password: $ARGOCD_PASSWORD"

# Instalar la CLI de ArgoCD
curl -sSL -o /usr/local/bin/argocd \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /usr/local/bin/argocd

# Login
argocd login localhost:8080 \
  --username admin \
  --password $ARGOCD_PASSWORD \
  --insecure

# Abrir en el navegador: http://localhost:8080
# Usuario: admin / Password: (el de arriba)
```

## Paso 3: Crear la primera Application desde CLI

```bash
# Desplegar una app desde el repositorio oficial de ejemplos de ArgoCD
argocd app create guestbook \
  --repo https://github.com/argoproj/argocd-example-apps.git \
  --path guestbook \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace workloads \
  --sync-policy automated \
  --auto-prune \
  --self-heal

# Ver el estado de la app
argocd app get guestbook
# Name:               guestbook
# Project:            default
# Server:             https://kubernetes.default.svc
# Namespace:          workloads
# URL:                http://localhost:8080/applications/guestbook
# Repo:               https://github.com/argoproj/argocd-example-apps.git
# Target:             HEAD
# Path:               guestbook
# Sync Policy:        Automated (Prune, SelfHeal)
# Sync Status:        Synced to HEAD
# Health Status:      Healthy

# Ver los recursos que ArgoCD desplegó
argocd app resources guestbook
# GROUP    KIND        NAMESPACE   NAME             STATUS   HEALTH
#          Service     workloads   guestbook-ui     Synced   Healthy
# apps     Deployment  workloads   guestbook-ui     Synced   Healthy
```

## Paso 4: Observar drift y self-healing

```bash
# Modificar manualmente un recurso (simular cambio no autorizado)
kubectl scale deployment guestbook-ui -n workloads --replicas=5

# ArgoCD detecta el drift (en el dashboard: estado = "OutOfSync")
argocd app get guestbook | grep "Sync Status"
# Sync Status: OutOfSync

# Con selfHeal=true, ArgoCD revierte automáticamente en ~3 segundos
sleep 10

kubectl get deployment guestbook-ui -n workloads -o jsonpath='{.spec.replicas}'
# 1  ← revertido a lo que dice Git

# Ver el historial de syncs
argocd app history guestbook
```

## Paso 5: Crear Application via YAML (enfoque GitOps puro)

```bash
# En GitOps puro, las Applications también están en Git
cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook-yaml
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io  # borra recursos del cluster al borrar la Application
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: helm-guestbook   # usa la versión con Helm chart
    helm:
      values: |
        replicaCount: 2
  destination:
    server: https://kubernetes.default.svc
    namespace: workloads
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF

argocd app get guestbook-yaml
```
