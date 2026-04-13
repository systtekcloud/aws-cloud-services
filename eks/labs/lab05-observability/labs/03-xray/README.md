# Sub-lab 03: X-Ray — Distributed Tracing

## Objetivo

Instrumentar una aplicación Python con el X-Ray SDK, desplegar el X-Ray Daemon como sidecar en el pod, y visualizar el Service Map en la consola de X-Ray.

---

## Cómo funciona X-Ray en EKS

```
App (Python/Java/Node) → X-Ray SDK
  │ UDP :2000 (localhost del pod)
  ▼
X-Ray Daemon (sidecar container)
  │ HTTPS → X-Ray API (aws xray PutTraceSegments)
  ▼
X-Ray Console
  ├─ Service Map: grafo de latencia entre servicios
  └─ Traces: drill-down de cada request individual
```

**¿Por qué sidecar y no DaemonSet?**
- En Fargate no hay acceso al host → no puede haber DaemonSet en el nodo
- Con sidecar: el SDK envía al daemon en localhost (misma red de pod)
- Con DaemonSet (en Managed Nodes): el SDK envía al IP del nodo

---

## Paso 1: Crear el rol IRSA para X-Ray

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_ID=$(aws eks describe-cluster --name eks-dev --query 'cluster.identity.oidc.issuer' --output text | cut -d'/' -f5)

aws iam create-role \
  --role-name eks-xray \
  --assume-role-policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": { \"Federated\": \"arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/${OIDC_ID}\" },
      \"Action\": \"sts:AssumeRoleWithWebIdentity\",
      \"Condition\": { \"StringEquals\": {
        \"oidc.eks.eu-west-1.amazonaws.com/id/${OIDC_ID}:sub\": \"system:serviceaccount:workloads:xray-sa\"
      }}
    }]
  }"

aws iam attach-role-policy \
  --role-name eks-xray \
  --policy-arn arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess

kubectl create serviceaccount xray-sa -n workloads
kubectl annotate serviceaccount xray-sa -n workloads \
  eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/eks-xray
```

## Paso 2: Desplegar app con X-Ray daemon sidecar

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: xray-demo
  namespace: workloads
spec:
  replicas: 2
  selector:
    matchLabels:
      app: xray-demo
  template:
    metadata:
      labels:
        app: xray-demo
    spec:
      serviceAccountName: xray-sa
      containers:

      # Aplicación principal con X-Ray SDK
      - name: app
        image: python:3.12-slim
        command: ["/bin/sh", "-c"]
        args:
        - |
          pip install flask aws-xray-sdk requests -q
          python -c "
          from flask import Flask
          from aws_xray_sdk.core import xray_recorder, patch_all
          from aws_xray_sdk.ext.flask.middleware import XRayMiddleware
          import requests, os

          app = Flask(__name__)
          xray_recorder.configure(
            service='xray-demo',
            daemon_address='127.0.0.1:2000'  # X-Ray daemon en localhost
          )
          XRayMiddleware(app, xray_recorder)
          patch_all()  # instrumenta boto3, requests automáticamente

          @app.route('/api/users')
          def users():
            with xray_recorder.in_subsegment('get-users'):
              return {'users': ['alice', 'bob', 'charlie']}

          @app.route('/api/slow')
          def slow():
            import time
            time.sleep(0.5)  # simula latencia
            return {'status': 'ok', 'latency_ms': 500}

          app.run(host='0.0.0.0', port=8080)
          "
        ports:
        - containerPort: 8080
        env:
        - name: AWS_DEFAULT_REGION
          value: eu-west-1
        resources:
          requests:
            cpu: "200m"
            memory: "256Mi"

      # X-Ray Daemon como sidecar
      - name: xray-daemon
        image: amazon/aws-xray-daemon:latest
        ports:
        - containerPort: 2000
          protocol: UDP
        resources:
          requests:
            cpu: "32m"
            memory: "24Mi"
          limits:
            cpu: "128m"
            memory: "64Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: xray-demo-svc
  namespace: workloads
spec:
  selector:
    app: xray-demo
  ports:
  - port: 80
    targetPort: 8080
EOF

kubectl wait deployment xray-demo -n workloads --for=condition=Available --timeout=120s
```

## Paso 3: Generar trazas

```bash
# Port-forward para acceder al servicio localmente
kubectl port-forward svc/xray-demo-svc 8080:80 -n workloads &

# Generar tráfico para crear trazas
for i in $(seq 1 20); do
  curl -s http://localhost:8080/api/users > /dev/null
  curl -s http://localhost:8080/api/slow > /dev/null
  sleep 1
done

# Ver trazas en X-Ray Console
echo "Abrir: https://eu-west-1.console.aws.amazon.com/xray/home"
```

## Paso 4: Explorar el Service Map y Traces

```
X-Ray Console → Service Map:
  - Nodos: cada microservicio instrumentado
  - Aristas: llamadas entre servicios (flecha = dirección del tráfico)
  - Color: verde (OK) / amarillo (throttle) / rojo (error)
  - Número en arista: solicitudes/minuto y latencia P99

X-Ray Console → Traces:
  - Timeline de cada request (cuánto tardó cada segmento)
  - Filtrar por: url, status_code, latencia
  - Ejemplo: filter responsetime > 0.3 → mostrar requests lentos

Queries de análisis:
  service("xray-demo") { responsetime > 0.5 }   ← requests >500ms
  service("xray-demo") { fault }                  ← requests con error 5xx
  service("xray-demo") { error }                  ← requests con error 4xx
```

## Paso 5: Alarma de X-Ray — Latencia P99 alta

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "xray-high-latency" \
  --namespace AWS/X-Ray \
  --metric-name ResponseTime \
  --dimensions Name=ServiceName,Value=xray-demo Name=ServiceType,Value=AWS::EC2::Instance \
  --statistic p99 \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 1.0 \
  --comparison-operator GreaterThanThreshold \
  --alarm-description "P99 latencia > 1s en xray-demo"
```
