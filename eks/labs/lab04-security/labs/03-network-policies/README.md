# Sub-lab 03: Network Policies

## Objetivo

Aplicar una política de deny-all por defecto en un namespace y luego añadir excepciones selectivas para aislar microservicios correctamente.

---

## Prerrequisito: CNI con soporte de NetworkPolicy

```bash
# VPC CNI (EKS por defecto) NO soporta NetworkPolicy.
# Necesitas Calico o Cilium.

# Instalar Calico (modo overlay para compatibilidad con VPC CNI)
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

# Verificar
kubectl get pods -n calico-system
```

---

## Paso 1: Crear namespaces de prueba

```bash
kubectl create namespace frontend
kubectl create namespace backend
kubectl create namespace database

# Desplegar pods de prueba en cada namespace
kubectl run web --image=nginx:alpine -n frontend --labels=app=web
kubectl run api --image=nginx:alpine -n backend --labels=app=api
kubectl run db  --image=nginx:alpine -n database --labels=app=db
kubectl expose pod web -n frontend --port=80
kubectl expose pod api -n backend --port=80
kubectl expose pod db  -n database --port=80
```

## Paso 2: Verificar conectividad inicial (sin policies)

```bash
# Sin NetworkPolicy: todos pueden hablar con todos
kubectl exec web -n frontend -- wget -qO- http://api.backend.svc.cluster.local
# HTML de nginx ← OK (sin restricciones)

kubectl exec web -n frontend -- wget -qO- http://db.database.svc.cluster.local
# HTML de nginx ← OK (PROBLEMA: frontend no debería acceder a DB directamente)
```

## Paso 3: Aplicar deny-all en el namespace database

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
  namespace: database
spec:
  podSelector: {}     # aplica a todos los pods del namespace
  policyTypes:
  - Ingress
  - Egress
  # sin reglas de allow → todo denegado
EOF

# Verificar que frontend ya no puede acceder a database
kubectl exec web -n frontend -- wget -qO- --timeout=5 http://db.database.svc.cluster.local
# wget: download timed out ← NetworkPolicy bloqueando
```

## Paso 4: Permitir solo el acceso de backend a database

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-backend
  namespace: database
spec:
  podSelector:
    matchLabels:
      app: db     # aplica solo al pod de DB
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: backend   # solo desde namespace backend
      podSelector:
        matchLabels:
          app: api   # solo del pod api
    ports:
    - protocol: TCP
      port: 80
EOF

# backend puede acceder a database
kubectl exec api -n backend -- wget -qO- --timeout=5 http://db.database.svc.cluster.local
# HTML de nginx ← OK

# frontend sigue sin poder acceder a database
kubectl exec web -n frontend -- wget -qO- --timeout=5 http://db.database.svc.cluster.local
# wget: download timed out ← bloqueado
```

## Paso 5: Política completa para microservicios

```bash
# Arquitectura objetivo:
#   Internet → frontend (puerto 80)
#   frontend → backend (puerto 8080)
#   backend → database (puerto 5432)
#   (ninguna otra comunicación permitida)

# Deny-all en todos los namespaces de prod
for ns in frontend backend database; do
  cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
  namespace: $ns
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
EOF
done

# Allow: Ingress externo → frontend
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-to-frontend
  namespace: frontend
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes: [Ingress, Egress]
  ingress:
  - ports:
    - port: 80
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: backend
    ports:
    - port: 80
EOF

# La red está ahora correctamente segmentada
echo "Verificar con kubectl exec + wget desde cada pod"
```
