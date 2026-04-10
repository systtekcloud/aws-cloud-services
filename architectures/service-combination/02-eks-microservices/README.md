# EKS + API Gateway + Cognito + X-Ray + ArgoCD: Plataforma SaaS B2B

**Tipo:** Service-Combination  
**Combinación:** EKS Fargate + API Gateway + Cognito + X-Ray + ArgoCD

**Caso de uso:** Plataforma SaaS B2B con múltiples tenants, microservicios en Kubernetes, autenticación federada y GitOps.

---

## ¿Por qué esta combinación no es obvia?

La duda habitual: si ya tienes EKS con ALB Ingress Controller, ¿para qué API Gateway?

| Sin API Gateway | Con API Gateway |
|----------------|-----------------|
| ALB → EKS directo | API GW → VPC Link → NLB → EKS |
| Throttling: manual (NGINX rate limit) | Throttling: nativo por API key / tenant |
| Auth: cada microservicio lo implementa | Auth: Cognito JWT centralizado en API GW |
| WAF: manual en ALB | WAF: nativo en API GW |
| Multi-tenant isolation: en código | Multi-tenant: Usage Plans por tenant en API GW |
| Coste: ALB por hora | Coste: API GW por request (mejor para tráfico irregular) |

**La combinación EKS + API GW hace que cada microservicio se enfoque en lógica de negocio**, no en auth/throttling/WAF.

---

## Arquitectura

```
Tenants B2B
  │ HTTPS con API Key + JWT (Cognito)
  ▼
API Gateway (REST)
  │ Cognito JWT Authorizer (valida token)
  │ Usage Plans (throttling por tenant: tier basic/pro/enterprise)
  │ WAF (SQL injection, rate limiting)
  ▼
VPC Link → NLB (Network Load Balancer)
  ▼
EKS Cluster (Fargate Profiles)
  │
  ├─ Namespace: tenant-{id}  (aislamiento por namespace)
  │   ├─ api-service (Deployment)
  │   ├─ worker-service (Deployment)
  │   └─ HPA (Horizontal Pod Autoscaler)
  │
  ├─ Namespace: platform
  │   ├─ ArgoCD (GitOps controller)
  │   ├─ Karpenter (node provisioning)
  │   └─ AWS Load Balancer Controller
  │
  └─ Namespace: observability
      ├─ X-Ray Daemon (tracing)
      ├─ Fluent Bit (logs → CloudWatch)
      └─ Container Insights

DynamoDB (datos por tenant, PK incluye tenant_id)
Cognito User Pool (con grupos por tenant y rol)
ArgoCD → GitHub repo (manifests por tenant)
```

---

## Multi-tenancy en EKS

Dos modelos de aislamiento:

**Namespace-per-tenant (este diseño):**
- Cada tenant tiene su namespace → RBAC y NetworkPolicies por namespace
- Un cluster para todos los tenants → economía de escala
- Aislamiento soft (si hay un pod comprometido, puede atacar otros namespaces sin NetworkPolicy)

**Cluster-per-tenant (alternativa):**
- Máximo aislamiento (blast radius = 1 tenant)
- Coste: cada cluster tiene overhead de ~$0.10/hora por el control plane
- 100 tenants = 100 clusters = $70/mes solo en control planes
- Usar solo para tenants enterprise con requisitos de compliance estrictos

---

## GitOps con ArgoCD

```
Developer → PR → GitHub (manifests por tenant)
              │
              ▼ merge a main
           ArgoCD detecta cambio (polling cada 3 min o webhook)
              │
              ▼
           kubectl apply (en el cluster)
              │
              ├─ Si OK: ArgoCD marca sync status = Synced
              └─ Si error: ArgoCD marca OutOfSync, alerta en Slack
```

**App of Apps pattern:**
```yaml
# apps/root-app.yaml → despliega todas las apps de todos los tenants
# apps/tenant-acme/api-service.yaml
# apps/tenant-acme/worker-service.yaml
# apps/tenant-beta/api-service.yaml
```

---

## Módulos Terraform

| Módulo | Recursos | Descripción |
|--------|----------|-------------|
| [modules/cluster/](modules/cluster/) | EKS + Fargate + IRSA | Infraestructura Kubernetes |
| [modules/platform/](modules/platform/) | API GW + Cognito + VPC Link | Capa de entrada |
| [modules/gitops/](modules/gitops/) | ArgoCD Helm + GitHub connection | GitOps controller |

---

## Recursos relacionados

- [design/multi-tenancy.md](design/multi-tenancy.md) — Namespace vs cluster isolation
- [scenarios/](scenarios/) — Onboarding de nuevo tenant, rollback GitOps, tenant quota
