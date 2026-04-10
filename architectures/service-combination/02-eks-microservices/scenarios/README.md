# Escenarios: EKS + API GW + Cognito + ArgoCD

## Escenario 1: Onboarding de nuevo tenant

**Proceso automatizado para añadir un tenant nuevo:**

```bash
# 1. Crear usuario en Cognito con tenant_id custom attribute
aws cognito-idp admin-create-user \
  --user-pool-id $POOL_ID \
  --username admin@acme.com \
  --user-attributes \
    Name=custom:tenant_id,Value=acme \
    Name=custom:role,Value=admin \
  --temporary-password TempPass123!

# 2. Crear API Key en API Gateway + asignar a Usage Plan
API_KEY=$(aws apigateway create-api-key --name "acme-key" --enabled --query 'id' --output text)
aws apigateway create-usage-plan-key \
  --usage-plan-id $BASIC_PLAN_ID \
  --key-id $API_KEY \
  --key-type API_KEY

# 3. Añadir manifests de Kubernetes para el nuevo tenant en GitHub
# (ArgoCD los detecta automáticamente en ~3 minutos)
cat > tenants/acme/namespace.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-acme
  labels:
    tenant: acme
    tier: basic
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-quota
  namespace: tenant-acme
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 4Gi
    pods: "10"
EOF

git add tenants/acme/ && git commit -m "feat: onboard tenant acme" && git push
# ArgoCD sincroniza en <3 min → namespace creado, pods running
```

---

## Escenario 2: Rollback GitOps cuando hay un bug en producción

**Situación:** el nuevo deploy de `api-service` tiene un bug que causa 500 errors.

```bash
# Opción 1: Rollback via Git (preferido — audit trail)
git revert HEAD  # revierte el commit del deploy
git push origin main
# ArgoCD detecta el cambio y hace rollback automático en <3 min

# Opción 2: Rollback directo en ArgoCD (más rápido)
argocd app rollback tenant-acme-api --revision 3  # vuelve a revision 3

# Opción 3: kubectl directo (EMERGENCIA — ArgoCD revertirá en la próxima sync)
kubectl rollout undo deployment/api-service -n tenant-acme
```

**Por qué preferir rollback via Git:**
- El cluster queda en sync con Git (GitOps puro)
- Queda el historial de quién hizo rollback y por qué (commit message)
- ArgoCD no marca el app como OutOfSync

---

## Escenario 3: Tenant supera su cuota de API Gateway

**Situación:** el tenant "acme" en plan Basic supera 10 req/s y empieza a recibir 429.

**Respuesta del API Gateway:**
```json
{
  "message": "Too Many Requests"
}
```

**Opciones:**
1. Upgrade a plan Enterprise (modificar Usage Plan en API GW)
2. El propio tenant implementa retry con backoff exponencial
3. Añadir SQS como buffer ante el tenant (cliente → SQS → microservicio) — el tenant procesa de manera asíncrona

**Upgrade automático:** si el tenant supera el 80% de su quota consistentemente (CloudWatch Alarm → Lambda → API GW UpdateUsagePlan).

---

## Escenario 4: X-Ray tracing entre API GW → EKS → DynamoDB

```
API GW → (tracing header X-Amzn-Trace-Id)
  ↓
NLB → EKS pod (X-Ray SDK en el microservicio)
  │ subsegmento: llamada a DynamoDB
  │ subsegmento: llamada a servicio interno
  ↓
X-Ray Service Map:
  API GW ──(2ms)── api-service ──(5ms)── DynamoDB
                       │
                    ──(15ms)── worker-service ──(3ms)── SQS
```

**Configuración en el microservicio Python:**
```python
from aws_xray_sdk.core import xray_recorder
from aws_xray_sdk.ext.flask.middleware import XRayMiddleware

app = Flask(__name__)
xray_recorder.configure(service='api-service', daemon_address='xray-daemon:2000')
XRayMiddleware(app, xray_recorder)

# DynamoDB calls instrumentadas automáticamente
from aws_xray_sdk.core import patch_all
patch_all()  # instrumenta boto3, requests, etc.
```

**X-Ray Daemon como sidecar en Fargate:**
```yaml
containers:
- name: api-service
  image: mi-api:latest
- name: xray-daemon
  image: amazon/aws-xray-daemon
  ports:
  - containerPort: 2000
    protocol: UDP
```
