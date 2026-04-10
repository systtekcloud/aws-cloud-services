# Concept Map: Amazon EKS

## Arquitectura de EKS

```
┌─────────────────────────────────────────────────────────────────┐
│  AWS Managed (Control Plane)          $0.10/hora               │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │  API Server  │  │     etcd     │  │  Scheduler/Controller│  │
│  │  (kubectl)   │  │  (estado)    │  │  Manager             │  │
│  └──────────────┘  └──────────────┘  └──────────────────────┘  │
│                          │                                      │
│           Multi-AZ: réplica automática                         │
└──────────────────────────┼──────────────────────────────────────┘
                           │ kubelet (comunicación segura)
┌──────────────────────────┼──────────────────────────────────────┐
│  Tu Data Plane            │                                     │
│                           │                                     │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Managed Node Group (EC2)  │  Fargate Profile           │   │
│  │  - Patch automático        │  - Sin EC2 que gestionar   │   │
│  │  - DaemonSets funcionan    │  - Pago por pod            │   │
│  │  - GPU soportado           │  - Sin DaemonSets          │   │
│  │  - Karpenter escala nodos  │  - Max 4 vCPU / 30GB       │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Control Plane — qué incluye AWS

- **API Server**: punto de entrada de todas las peticiones (kubectl, IRSA, webhooks)
- **etcd**: almacén de estado del cluster. AWS lo replica en 3 AZs
- **Scheduler**: decide en qué nodo va cada pod (afinidad, recursos, taints)
- **Controller Manager**: mantiene el estado deseado (si un pod muere, lo recrea)
- **Cloud Controller Manager**: integración con AWS (crea ELBs cuando hay un Service LoadBalancer)

**SLA**: 99.95% para el control plane. Tu data plane es tu responsabilidad.

## VPC CNI — cómo funciona la red en EKS

```
Cada pod recibe una IP de la VPC (no una IP overlay como en otros k8s)
  ↓
Pod en node EC2 → IP de la ENI del nodo → IP de la VPC
  ↓
Ventaja: pods acceden a RDS, ElastiCache, etc. sin NAT
  ↓
Limitación: subnets deben tener suficientes IPs (una por pod)
  → Para 100 pods: subnet /24 (254 IPs) OK, /28 (14 IPs) NO
```

## Fargate vs Managed Node Groups

```
¿Necesitas DaemonSets?          → Managed Nodes
¿Necesitas GPU?                 → Managed Nodes
¿Máxima carga > 4vCPU/30GB?    → Managed Nodes
¿Pods de larga duración?        → Managed Nodes (coste EC2 es mejor)

¿Cargas variables/batch?        → Fargate
¿Sin ops de nodos?              → Fargate
¿Pods cortos (<10 min)?         → Fargate (pago por segundo)
¿Ya tienes EKS y quieres mezclar? → Fargate Profile para namespaces específicos
```

**Fargate cold start:** el primer pod en un namespace tarda ~30-90s (aprovisionamiento microVM).
Los siguientes pods en el mismo namespace son más rápidos.

## IRSA — IAM Roles for Service Accounts

**Problema que resuelve:** los pods necesitan llamar a AWS (S3, DynamoDB, SQS). Sin IRSA, las opciones son malas:
- `AWS_ACCESS_KEY_ID` en el código → inseguro
- Rol del nodo EC2 → todos los pods del nodo tienen el mismo rol

**Solución IRSA:**
```
1. EKS OIDC Provider (trust entre EKS y IAM)
2. ServiceAccount con anotación → IAM Role ARN
3. Pod usa esa ServiceAccount
4. SDK de AWS detecta el token del pod automáticamente
5. IAM valida el token via OIDC
6. Pod recibe credenciales temporales del rol IAM
```

```yaml
# ServiceAccount con anotación IRSA
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mi-app
  namespace: produccion
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789:role/mi-app-role
```

```hcl
# IAM Role — trust policy que permite asumir desde EKS
resource "aws_iam_role" "mi_app" {
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = "arn:aws:iam::123456789:oidc-provider/..." }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "oidc.eks.eu-west-1.amazonaws.com/id/XXXXX:sub" = "system:serviceaccount:produccion:mi-app"
        }
      }
    }]
  })
}
```

**El pod no necesita saber nada de esto.** El SDK de AWS busca automáticamente `AWS_WEB_IDENTITY_TOKEN_FILE` (inyectado por EKS) y llama a STS.

## Networking: Load Balancers en EKS

```
Tipo Service LoadBalancer → CLB/NLB (solo L4, TCP/UDP)
  → annotations: service.beta.kubernetes.io/aws-load-balancer-type: nlb

Tipo Ingress (via ALB Ingress Controller) → ALB (L7, HTTP/HTTPS)
  → annotations: kubernetes.io/ingress.class: alb
  → Una regla Ingress = una regla en el ALB (no un ALB por Ingress)
  → Permite routing por path, host-based, HTTPS termination

VPC Link (para API Gateway → EKS):
  → API GW → VPC Link → NLB → NodePort → Pod
```

## Add-ons gestionados

| Add-on | Función | Gestión |
|--------|---------|---------|
| VPC CNI | Asigna IPs de VPC a pods | AWS Managed |
| CoreDNS | DNS interno del cluster | AWS Managed |
| kube-proxy | Reglas de red (iptables/ipvs) | AWS Managed |
| EBS CSI | Persistent Volumes en EBS | AWS Managed |
| EFS CSI | Volumes compartidos en EFS | AWS Managed |

Actualizar add-ons vía CLI:
```bash
aws eks update-addon --cluster-name mi-cluster --addon-name vpc-cni --addon-version v1.18.0-eksbuild.1
```
