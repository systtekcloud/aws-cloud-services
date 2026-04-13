# Sub-lab 02: App of Apps Pattern

## Objetivo

Gestionar múltiples aplicaciones desde un único punto de entrada en Git. La "root app" en Git controla qué aplicaciones se despliegan y con qué configuración.

---

## El patrón

```
Root Application (en ArgoCD)
  │ apunta a → apps/ en el repo Git
  │
  ▼ ArgoCD sincroniza
apps/
  ├─ api-service-app.yaml    → Application para api-service
  ├─ worker-app.yaml         → Application para worker
  └─ monitoring-app.yaml     → Application para stack de monitoring

Cada Application.yaml apunta a otro path/repo:
  api-service-app.yaml → services/api-service/ → Deployment + Service
  worker-app.yaml      → services/worker/      → Deployment + ConfigMap
```

**Beneficio:** para añadir una nueva aplicación, solo se hace un `git push` con el YAML de la Application. ArgoCD despliega automáticamente.

---

## Estructura del repositorio de manifests

```
gitops-repo/
├── apps/
│   ├── dev/
│   │   ├── root.yaml           ← Root Application para dev
│   │   ├── api-service.yaml    ← Application para api-service en dev
│   │   └── worker.yaml         ← Application para worker en dev
│   └── prod/
│       ├── root.yaml
│       ├── api-service.yaml
│       └── worker.yaml
├── services/
│   ├── api-service/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── hpa.yaml
│   └── worker/
│       ├── deployment.yaml
│       └── configmap.yaml
└── infrastructure/
    ├── monitoring/
    └── ingress-controller/
```

---

## Paso 1: Crear la estructura en tu repo

```bash
# Crear un repositorio de ejemplo en GitHub (o usar el tuyo)
# Para el lab usaremos la estructura local

mkdir -p /tmp/gitops-demo/apps/dev
mkdir -p /tmp/gitops-demo/services/api-service
mkdir -p /tmp/gitops-demo/services/worker
cd /tmp/gitops-demo
git init && git remote add origin https://github.com/TU-USUARIO/gitops-demo.git
```

## Paso 2: Crear las Application de cada servicio

```bash
# apps/dev/api-service.yaml
cat > /tmp/gitops-demo/apps/dev/api-service.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: api-service-dev
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/TU-USUARIO/gitops-demo.git
    targetRevision: HEAD
    path: services/api-service
  destination:
    server: https://kubernetes.default.svc
    namespace: dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF

# apps/dev/worker.yaml
cat > /tmp/gitops-demo/apps/dev/worker.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: worker-dev
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/TU-USUARIO/gitops-demo.git
    targetRevision: HEAD
    path: services/worker
  destination:
    server: https://kubernetes.default.svc
    namespace: dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
```

## Paso 3: Crear los manifests de los servicios

```bash
# services/api-service/deployment.yaml
cat > /tmp/gitops-demo/services/api-service/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-service
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api-service
  template:
    metadata:
      labels:
        app: api-service
    spec:
      containers:
      - name: api
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
EOF

# services/worker/deployment.yaml
cat > /tmp/gitops-demo/services/worker/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worker
spec:
  replicas: 1
  selector:
    matchLabels:
      app: worker
  template:
    metadata:
      labels:
        app: worker
    spec:
      containers:
      - name: worker
        image: busybox:1.36
        command: ["/bin/sh", "-c", "while true; do echo 'worker running'; sleep 10; done"]
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
EOF
```

## Paso 4: Root Application

```bash
# apps/dev/root.yaml — la App que gestiona todas las demás Apps
cat > /tmp/gitops-demo/apps/dev/root.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-dev
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/TU-USUARIO/gitops-demo.git
    targetRevision: HEAD
    path: apps/dev          # ← apunta al directorio que contiene las sub-Applications
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd       # las Applications van en el namespace de argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

# Hacer push al repo
cd /tmp/gitops-demo
git add . && git commit -m "feat: initial app of apps structure"
git push origin main

# Crear SOLO la root application en ArgoCD (el resto lo gestiona la root)
kubectl apply -f /tmp/gitops-demo/apps/dev/root.yaml

# ArgoCD despliega la root → la root despliega api-service y worker → servicios running
argocd app list
# NAME              CLUSTER                         NAMESPACE   STATUS   HEALTH
# root-dev          https://kubernetes.default.svc  argocd      Synced   Healthy
# api-service-dev   https://kubernetes.default.svc  dev         Synced   Healthy
# worker-dev        https://kubernetes.default.svc  dev         Synced   Healthy
```

## Paso 5: Añadir una nueva app (flujo GitOps completo)

```bash
# Para añadir "monitoring" al stack: solo añadir un fichero en apps/dev/
cat > /tmp/gitops-demo/apps/dev/monitoring.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring-dev
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argo-cd.git  # repo externo con charts
    targetRevision: HEAD
    path: examples/helm-guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF

git add apps/dev/monitoring.yaml
git commit -m "feat: add monitoring to dev stack"
git push origin main

# ArgoCD detecta el cambio en apps/dev/ → despliega monitoring-dev automáticamente
# Sin ningún kubectl apply manual
sleep 30
argocd app list | grep monitoring
# monitoring-dev   Synced   Healthy
```
