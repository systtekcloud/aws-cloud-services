# Sub-lab 01: HPA — Horizontal Pod Autoscaler

## Objetivo

Configurar HPA para escalar pods automáticamente basado en CPU, observar el proceso con un load test, y entender el comportamiento de scale-down.

---

## Paso 1: Instalar metrics-server

```bash
# metrics-server es necesario para que HPA pueda leer CPU/memoria de los pods
# En EKS con Fargate está incluido en los add-ons gestionados

# Verificar que metrics-server está funcionando
kubectl top nodes
kubectl top pods -n kube-system

# Si no está instalado:
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

## Paso 2: Desplegar aplicación con requests de CPU definidos

```bash
# HPA requiere que el pod tenga resources.requests.cpu definido
# Sin requests, HPA no puede calcular el porcentaje de uso

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cpu-stress
  namespace: workloads
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cpu-stress
  template:
    metadata:
      labels:
        app: cpu-stress
    spec:
      containers:
      - name: stress
        image: nginx:1.27-alpine
        resources:
          requests:
            cpu: "200m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "256Mi"
        readinessProbe:
          httpGet: { path: /, port: 80 }
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: cpu-stress-svc
  namespace: workloads
spec:
  selector:
    app: cpu-stress
  ports:
  - port: 80
    targetPort: 80
EOF
```

## Paso 3: Crear el HPA

```bash
cat <<EOF | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: cpu-stress-hpa
  namespace: workloads
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: cpu-stress
  minReplicas: 1
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50  # objetivo: 50% de CPU del request
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 60  # esperar 60s antes de scale-down (lab: más corto que prod)
      policies:
      - type: Pods
        value: 2
        periodSeconds: 30  # máximo: bajar 2 pods cada 30s
    scaleUp:
      stabilizationWindowSeconds: 0  # scale-up inmediato
      policies:
      - type: Pods
        value: 4
        periodSeconds: 30  # máximo: subir 4 pods cada 30s
EOF

# Ver el HPA
kubectl get hpa cpu-stress-hpa -n workloads
# NAME             REFERENCE           TARGETS   MINPODS   MAXPODS   REPLICAS
# cpu-stress-hpa   Deployment/cpu-stress   0%/50%   1         10        1
```

## Paso 4: Load test para disparar scale-up

```bash
# Pod generador de carga (en namespace separado para no interferir)
kubectl run load-generator \
  --image=busybox:1.36 \
  --restart=Never \
  -n default \
  -- /bin/sh -c "while true; do wget -q -O- http://cpu-stress-svc.workloads.svc.cluster.local; done"

# En otra terminal: observar el HPA en tiempo real
watch kubectl get hpa cpu-stress-hpa -n workloads
# TARGETS    MINPODS   MAXPODS   REPLICAS
# 85%/50%    1         10        1   ← CPU subiendo, todavía sin escalar
# 85%/50%    1         10        3   ← HPA escala a 3
# 72%/50%    1         10        5   ← escala más

# Ver cómo el tráfico se distribuye entre pods
kubectl get pods -n workloads -l app=cpu-stress
```

## Paso 5: Observar el scale-down

```bash
# Parar el generador de carga
kubectl delete pod load-generator -n default

# Observar el scale-down (tarda ~60s por el stabilizationWindow)
watch kubectl get hpa cpu-stress-hpa -n workloads
# TARGETS   REPLICAS
# 0%/50%    5   ← CPU = 0 pero stabilizationWindow activo
# 0%/50%    3   ← bajando gradualmente
# 0%/50%    1   ← mínimo alcanzado

# Ver eventos del HPA para entender las decisiones
kubectl describe hpa cpu-stress-hpa -n workloads | grep -A 20 Events
```

## Qué observar

1. **El HPA revisa métricas cada 15 segundos** (configurable con `--horizontal-pod-autoscaler-sync-period`)
2. **Scale-up es más agresivo que scale-down** (por diseño — mejor tener pods de más que de menos)
3. **Los pods nuevos aparecen en el Service inmediatamente** cuando pasan el readinessProbe
4. **Con Fargate:** los pods nuevos tardan ~30-90s en estar Ready (cold start de microVM)
