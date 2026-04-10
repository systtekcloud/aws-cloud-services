# Concept Map: Workloads en EKS

## Jerarquía de objetos

```
Deployment
  └─ gestiona → ReplicaSet (actual)
                    └─ gestiona → Pods (N réplicas)

kubectl apply -f deployment.yaml
  → Deployment crea ReplicaSet nuevo
  → ReplicaSet crea Pods gradualmente (rolling update)
  → ReplicaSet antiguo escala a 0 (queda para rollback)
```

## Rolling Update

```
Configuración:
  maxUnavailable: 1   ← máximo pods no disponibles durante update
  maxSurge: 1         ← máximo pods extras durante update

Estado con 3 réplicas (v1 → v2):

Inicio:   [v1] [v1] [v1]
Paso 1:   [v1] [v1] [v2] ← 1 nuevo creado (surge=1)
Paso 2:   [v1] [--] [v2] ← 1 antiguo terminado (unavailable=1)
Paso 3:   [v1] [v2] [v2]
Paso 4:   [--] [v2] [v2]
Fin:      [v2] [v2] [v2]
```

**Rollback:**
```bash
kubectl rollout undo deployment/mi-app
kubectl rollout undo deployment/mi-app --to-revision=3
kubectl rollout history deployment/mi-app
```

## Tipos de Service

```
ClusterIP (default)
  - IP virtual solo accesible dentro del cluster
  - Uso: comunicación entre microservicios
  - kube-proxy crea reglas iptables para balancear entre pods

NodePort
  - Puerto en todos los nodos (30000-32767)
  - Uso: acceso externo en entornos dev sin cloud provider
  - Agrega ClusterIP automáticamente

LoadBalancer
  - Crea un ELB (CLB por defecto, NLB con anotación)
  - Uso: exponer servicios en producción
  - Una IP externa por Service → costoso si hay muchos services

Ingress (+ ALB Ingress Controller)
  - Un ALB para múltiples services (routing L7)
  - Uso: múltiples servicios bajo el mismo dominio
  - Más barato: 1 ALB en vez de N ELBs
```

## ALB Ingress Controller — cómo funciona

```
1. Instalar ALB Ingress Controller en el cluster (vía Helm)
   - Necesita IRSA con permisos para crear/modificar ALBs en AWS

2. Crear un recurso Ingress en Kubernetes:
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     annotations:
       kubernetes.io/ingress.class: alb
       alb.ingress.kubernetes.io/scheme: internet-facing
   spec:
     rules:
     - host: api.mi-app.com
       http:
         paths:
         - path: /api
           backend:
             service:
               name: api-service
               port:
                 number: 80
         - path: /admin
           backend:
             service:
               name: admin-service
               port:
                 number: 80

3. ALB Ingress Controller detecta el Ingress y crea en AWS:
   - Application Load Balancer (internet-facing o internal)
   - Target Groups (uno por Service/path)
   - Listener Rules (HTTP 80, HTTPS 443)
   - Certificado ACM (si se especifica alb.ingress.kubernetes.io/certificate-arn)
```

**IngressGroup:** agrupa múltiples Ingress en el mismo ALB:
```yaml
annotations:
  alb.ingress.kubernetes.io/group.name: mi-app  # mismo ALB para todos los Ingress con este grupo
```

## Health Probes

```yaml
livenessProbe:    # Si falla: restart del contenedor
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 30  # esperar antes del primer check
  periodSeconds: 10         # frecuencia
  failureThreshold: 3       # fallos consecutivos para restart

readinessProbe:   # Si falla: pod sale del Service (sin tráfico)
  httpGet:
    path: /ready
    port: 8080
  periodSeconds: 5
  failureThreshold: 2

startupProbe:     # Si falla: restart. Permite apps lentas en arrancar.
  httpGet:
    path: /health
    port: 8080
  failureThreshold: 30    # 30 × 10s = 5 minutos para arrancar
  periodSeconds: 10
```

**Cuándo usar cada uno:**
- `livenessProbe`: para detectar estados bloqueados (deadlock, OOM sin crash)
- `readinessProbe`: siempre — evita tráfico a pods que no están listos
- `startupProbe`: apps lentas en iniciar (Java con Spring Boot, apps que cargan modelos ML)

## Resource Requests y Limits

```yaml
resources:
  requests:          # lo que el scheduler usa para colocar el pod
    cpu: "250m"      # 0.25 vCPU
    memory: "256Mi"
  limits:            # el pod no puede superar esto
    cpu: "500m"      # si supera: throttled (no killed)
    memory: "512Mi"  # si supera: OOMKilled
```

**En Fargate:** los requests determinan el tamaño de la microVM. No hay throttling por CPU (el pod tiene los vCPU que pidió).

**QoS classes:**
- `Guaranteed`: requests == limits → más estable, menos evictable
- `Burstable`: requests < limits → puede usar más si hay recursos
- `BestEffort`: sin requests/limits → primer candidato a evicción
