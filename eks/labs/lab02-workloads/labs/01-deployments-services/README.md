# Sub-lab 01: Deployments y Services

## Objetivo

Desplegar una aplicación con múltiples réplicas, hacer un rolling update, observar el proceso, y exponerla con diferentes tipos de Service.

---

## Paso 1: Crear el Deployment

```bash
# Namespace para el lab
kubectl create namespace workloads

# Deployment: aplicación demo (3 réplicas)
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: workloads
spec:
  replicas: 3
  selector:
    matchLabels:
      app: demo
      version: v1
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
  template:
    metadata:
      labels:
        app: demo
        version: v1
    spec:
      containers:
      - name: demo
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "200m"
            memory: "256Mi"
        readinessProbe:
          httpGet:
            path: /
            port: 80
          periodSeconds: 5
          failureThreshold: 2
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 10
EOF

# Ver el rollout
kubectl rollout status deployment/demo-app -n workloads
# Waiting for deployment "demo-app" rollout to finish: 0 of 3 updated replicas are available...
# deployment "demo-app" successfully rolled out

# Ver los pods
kubectl get pods -n workloads -o wide
# NAME                       READY   STATUS    NODE
# demo-app-xxx-aaa          1/1     Running   fargate-ip-10-30-0-x
# demo-app-xxx-bbb          1/1     Running   fargate-ip-10-30-0-y
# demo-app-xxx-ccc          1/1     Running   fargate-ip-10-30-0-z
```

## Paso 2: Crear un Service ClusterIP

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: demo-svc
  namespace: workloads
spec:
  selector:
    app: demo  # selecciona pods con este label
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
EOF

# Ver la IP del Service
kubectl get svc demo-svc -n workloads
# NAME       TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
# demo-svc   ClusterIP   172.20.x.x      <none>        80/TCP    5s

# Probar desde dentro del cluster
kubectl run curl --image=curlimages/curl --restart=Never -n workloads -- \
  curl -s http://demo-svc/
kubectl logs curl -n workloads
kubectl delete pod curl -n workloads
```

## Paso 3: Rolling update

```bash
# Actualizar la imagen (v1 → v2 simulado con nginx:1.26-alpine)
kubectl set image deployment/demo-app demo=nginx:1.26-alpine -n workloads

# Observar el rolling update en tiempo real
kubectl rollout status deployment/demo-app -n workloads -w
# Waiting for deployment "demo-app" rollout to finish: 1 out of 3 new replicas have been updated...
# Waiting for deployment "demo-app" rollout to finish: 2 out of 3 new replicas have been updated...
# deployment "demo-app" successfully rolled out

# Ver el historial de ReplicaSets
kubectl get replicasets -n workloads
# NAME                   DESIRED   CURRENT   READY   AGE
# demo-app-abc123        3         3         3       2m   ← nuevo (nginx:1.26)
# demo-app-xyz789        0         0         0       5m   ← antiguo (nginx:1.27)

# Hacer rollback
kubectl rollout undo deployment/demo-app -n workloads
kubectl rollout status deployment/demo-app -n workloads
```

## Paso 4: Service LoadBalancer (NLB)

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: demo-nlb
  namespace: workloads
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
spec:
  selector:
    app: demo
  ports:
  - port: 80
    targetPort: 80
  type: LoadBalancer
EOF

# Esperar a que el NLB se cree (1-2 min)
kubectl get svc demo-nlb -n workloads -w
# NAME       TYPE           CLUSTER-IP     EXTERNAL-IP                                            PORT(S)
# demo-nlb   LoadBalancer   172.20.x.x     xxx.elb.eu-west-1.amazonaws.com                        80:31234/TCP

# Probar desde fuera del cluster
NLB_DNS=$(kubectl get svc demo-nlb -n workloads -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s http://$NLB_DNS | head -5
```

## Paso 5: Observar el comportamiento con pod fallido

```bash
# Simular que un pod falla (proceso muere)
POD=$(kubectl get pods -n workloads -l app=demo -o name | head -1)
kubectl exec $POD -n workloads -- kill 1

# El pod se marca como Failed y Deployment crea uno nuevo
kubectl get pods -n workloads -w
# NAME              READY   STATUS      RESTARTS
# demo-app-xxx-aaa  0/1     Error       1         ← falló
# demo-app-xxx-aaa  1/1     Running     1         ← reiniciado (liveness probe lo detectó antes)
```
