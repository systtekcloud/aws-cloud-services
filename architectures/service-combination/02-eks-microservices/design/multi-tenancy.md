# Multi-tenancy en EKS

## Modelo 1: Namespace-per-tenant (este diseño)

```
EKS Cluster
├── namespace: tenant-acme
│   ├── api-service (pods)
│   ├── ResourceQuota: CPU 4, Memory 8Gi
│   └── NetworkPolicy: solo acepta tráfico del NLB
├── namespace: tenant-beta
│   └── ...
└── namespace: platform (ArgoCD, monitoring)
```

**RBAC por tenant:**
```yaml
# Un ServiceAccount por tenant, solo acceso a su namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-acme-access
  namespace: tenant-acme
subjects:
- kind: ServiceAccount
  name: tenant-acme-sa
roleRef:
  kind: Role
  name: tenant-developer
  apiGroup: rbac.authorization.k8s.io
```

**NetworkPolicy (bloquear tráfico entre tenants):**
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-cross-tenant
  namespace: tenant-acme
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: tenant-acme    # solo desde mismo namespace
    - namespaceSelector:
        matchLabels:
          name: platform        # o desde platform (monitoring)
```

**ResourceQuota por tenant (según plan contratado):**
```yaml
# Tier Basic
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-quota
  namespace: tenant-acme
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 4Gi
    limits.cpu: "4"
    limits.memory: 8Gi
    pods: "10"
```

## Modelo 2: Cluster-per-tenant (alternativa enterprise)

```
EKS Cluster "acme-prod"     → solo tenant Acme
EKS Cluster "beta-prod"     → solo tenant Beta
EKS Cluster "platform"      → ArgoCD gestiona todos
```

**Cuándo usar:**
- Compliance estricto (tenant paga por aislamiento total)
- Tenant tiene su propio equipo de operaciones
- Diferentes regiones por tenant
- >$10K/mes de ARR por tenant (justifica el coste extra del cluster)

**Coste adicional:** $0.10/hora por control plane × 720h = $72/mes/tenant.

## Gestión de configuración por tenant en DynamoDB

```python
# Cada request lleva el tenant_id en el JWT (Cognito claim)
# El microservicio lo usa como parte de la PK en DynamoDB:

PK = f"{tenant_id}#{recurso_id}"  # ej: "acme#order-123"

# Nunca puede haber colisión entre tenants
# Sin necesidad de filtrar por tenant_id en las queries
```

**Alternativa: tabla DynamoDB por tenant**
- Pros: aislamiento completo de datos, backup/restore por tenant
- Contras: 100 tenants = 100 tablas (difícil de gestionar, cuota AWS de 2500 tablas/región)
- Usar solo si hay requisitos legales de separación de datos (GDPR, datos en diferentes países)
