# Sub-lab 02: ALB Ingress Controller

## Objetivo

Instalar el AWS Load Balancer Controller, crear reglas de Ingress con routing por path y host, y habilitar HTTPS con ACM.

---

## Paso 1: Instalar AWS Load Balancer Controller

```bash
# El rol IRSA ya fue creado en lab01 (terraform output alb_controller_role_arn)
ALB_ROLE_ARN=$(terraform -chdir=../../terraform output -raw alb_controller_role_arn)
CLUSTER_NAME="eks-dev"

# Crear ServiceAccount con la anotación IRSA
kubectl create serviceaccount aws-load-balancer-controller -n kube-system

kubectl annotate serviceaccount aws-load-balancer-controller -n kube-system \
  eks.amazonaws.com/role-arn=$ALB_ROLE_ARN

# Instalar el controller via Helm
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

# Verificar que el controller está running
kubectl get deployment aws-load-balancer-controller -n kube-system
# NAME                           READY   UP-TO-DATE   AVAILABLE
# aws-load-balancer-controller   2/2     2            2
```

## Paso 2: Desplegar dos servicios de backend

```bash
# Servicio A: API backend
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-backend
  namespace: workloads
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api-backend
  template:
    metadata:
      labels:
        app: api-backend
    spec:
      containers:
      - name: api
        image: hashicorp/http-echo:latest
        args: ["-text=respuesta del API backend"]
        ports:
        - containerPort: 5678
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: api-backend-svc
  namespace: workloads
spec:
  selector:
    app: api-backend
  ports:
  - port: 80
    targetPort: 5678
EOF

# Servicio B: Web frontend
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-frontend
  namespace: workloads
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web-frontend
  template:
    metadata:
      labels:
        app: web-frontend
    spec:
      containers:
      - name: web
        image: hashicorp/http-echo:latest
        args: ["-text=respuesta del Web frontend"]
        ports:
        - containerPort: 5678
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: web-frontend-svc
  namespace: workloads
spec:
  selector:
    app: web-frontend
  ports:
  - port: 80
    targetPort: 5678
EOF

kubectl wait deployment api-backend web-frontend -n workloads \
  --for=condition=Available --timeout=120s
```

## Paso 3: Crear Ingress con routing por path

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: mi-app-ingress
  namespace: workloads
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip  # Para Fargate: ip (no instance)
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
spec:
  rules:
  - http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: api-backend-svc
            port:
              number: 80
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-frontend-svc
            port:
              number: 80
EOF

# Esperar a que el ALB se cree (1-3 min)
kubectl get ingress mi-app-ingress -n workloads -w
# NAME              CLASS   HOSTS   ADDRESS                                PORT(S)   AGE
# mi-app-ingress    <none>  *       xxx.eu-west-1.elb.amazonaws.com        80        2m

ALB_DNS=$(kubectl get ingress mi-app-ingress -n workloads \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Probar routing por path
curl http://$ALB_DNS/api    # respuesta del API backend
curl http://$ALB_DNS/       # respuesta del Web frontend
```

## Paso 4: IngressGroup (compartir el mismo ALB entre múltiples Ingress)

```bash
# Sin IngressGroup: cada Ingress = 1 ALB = $16-24/mes
# Con IngressGroup: todos los Ingress del grupo comparten 1 ALB

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: admin-ingress
  namespace: workloads
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/group.name: mi-app      # mismo grupo → mismo ALB
    alb.ingress.kubernetes.io/group.order: "10"        # orden de las reglas
spec:
  rules:
  - http:
      paths:
      - path: /admin
        pathType: Prefix
        backend:
          service:
            name: api-backend-svc
            port:
              number: 80
EOF

# Ambos Ingress (mi-app-ingress y admin-ingress) ahora usan el mismo ALB
kubectl get ingress -n workloads
# NAME              ADDRESS                                 PORT(S)
# mi-app-ingress    xxx.eu-west-1.elb.amazonaws.com        80      ← mismo ALB
# admin-ingress     xxx.eu-west-1.elb.amazonaws.com        80      ← mismo ALB
```

## Paso 5: HTTPS con ACM (opcional, requiere dominio propio)

```bash
# Obtener el ARN del certificado ACM
CERT_ARN="arn:aws:acm:eu-west-1:123456789:certificate/xxx"

# Añadir anotaciones HTTPS al Ingress
kubectl annotate ingress mi-app-ingress -n workloads \
  "alb.ingress.kubernetes.io/listen-ports=[{\"HTTP\": 80}, {\"HTTPS\": 443}]" \
  "alb.ingress.kubernetes.io/certificate-arn=$CERT_ARN" \
  "alb.ingress.kubernetes.io/ssl-redirect=443"  # redirigir HTTP → HTTPS

# El ALB Ingress Controller actualiza el ALB automáticamente
```

## Observaciones clave

1. **`target-type: ip` es obligatorio en Fargate** (no hay nodos EC2 con NodePort)
2. **IngressGroup** evita el coste de múltiples ALBs ($16-24/mes cada uno)
3. **El ALB se crea en subnets con tag `kubernetes.io/role/elb: 1`** (internet-facing) o `kubernetes.io/role/internal-elb: 1` (internal) — estos tags los añade el módulo Terraform de lab01
