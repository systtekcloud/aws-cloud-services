# Escenarios: EKS Cluster

## Escenario 1: ¿Fargate o Managed Node Groups?

**Árbol de decisión:**

```
¿Necesitas DaemonSets?
  Sí → Managed Nodes (Fargate no soporta DaemonSets)
  No → ↓

¿Necesitas GPU?
  Sí → Managed Nodes con instancias p3/g4/g5
  No → ↓

¿Los pods necesitan >4 vCPU o >30 GB RAM?
  Sí → Managed Nodes (Fargate max: 4 vCPU / 30 GB)
  No → ↓

¿El tráfico es predecible y constante?
  Sí → Managed Nodes (EC2 reservado es más barato para uso constante)
  No → Fargate (pago por segundo, sin EC2 idle)

¿Tienes requisitos de compliance de nodo específicos?
  Sí → Managed Nodes (puedes customizar el AMI)
  No → Fargate (AWS gestiona la seguridad de la microVM)
```

**Ejemplo de coste:**

Para 10 pods de 0.5 vCPU / 1 GB RAM ejecutándose 24/7:
- Fargate: 10 × (0.5 vCPU × $0.04048/vCPU-hora + 1GB × $0.004445/GB-hora) × 720h = $161/mes
- Managed Nodes (m5.large: 2vCPU/8GB): 1 nodo × $0.096/hora × 720h = $69/mes

→ **Managed Nodes es más barato para uso constante.** Fargate solo gana con cargas muy variables (0% de uso muchas horas).

---

## Escenario 2: Cluster upgrade (sin downtime)

EKS soporta upgrades in-place del control plane y nodos:

```bash
# 1. Verificar la versión actual
kubectl version
aws eks describe-cluster --name eks-lab --query 'cluster.version'

# 2. Actualizar add-ons antes del cluster (compatibilidad)
aws eks update-addon --cluster-name eks-lab --addon-name vpc-cni --addon-version v1.18.0-eksbuild.1
aws eks update-addon --cluster-name eks-lab --addon-name coredns --addon-version v1.11.1-eksbuild.6

# 3. Actualizar el control plane (solo una versión menor a la vez: 1.29 → 1.30)
aws eks update-cluster-version --name eks-lab --kubernetes-version 1.31
# Tarda 15-20 minutos. El control plane se actualiza sin downtime.

# 4. Para Fargate: los pods se recrean automáticamente en la nueva versión
#    cuando se hace un rollout

# 5. Para Managed Nodes: actualizar el Node Group
aws eks update-nodegroup-version --cluster-name eks-lab --nodegroup-name default
# Hace rolling update: cordon, drain, terminate nodo antiguo, nuevo nodo con nueva versión
```

**Política de soporte:** EKS soporta las últimas 3 versiones menores. Cuando una versión se depreca, los clusters se actualizan automáticamente (con aviso previo de 60 días).

---

## Escenario 3: Acceso al cluster desde CI/CD (GitHub Actions)

```yaml
# .github/workflows/deploy.yml
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write  # Para OIDC con AWS
      contents: read
    steps:
    - uses: actions/checkout@v4

    - name: Configure AWS via OIDC (sin credenciales estáticas)
      uses: aws-actions/configure-aws-credentials@v4
      with:
        role-to-assume: arn:aws:iam::123456789:role/github-eks-deploy
        aws-region: eu-west-1

    - name: Update kubeconfig
      run: aws eks update-kubeconfig --name eks-lab --region eu-west-1

    - name: Deploy
      run: kubectl apply -f k8s/
```

**IAM Role para GitHub Actions (OIDC):**
```hcl
resource "aws_iam_role" "github_eks" {
  name = "github-eks-deploy"
  assume_role_policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = "arn:aws:iam::...:oidc-provider/token.actions.githubusercontent.com" }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:mi-org/mi-repo:ref:refs/heads/main"
        }
      }
    }]
  })
}
```

---

## Escenario 4: Acceso a recursos AWS desde pods sin IRSA (anti-patrón)

**Lo que NO hacer:**

```yaml
# MAL: credenciales en env vars
env:
- name: AWS_ACCESS_KEY_ID
  value: AKIAXXXXXXXXXXXXXXXX
- name: AWS_SECRET_ACCESS_KEY
  value: secreto

# MAL: credenciales en Secret de Kubernetes
# Los Secrets de k8s no están cifrados por defecto en etcd
# Solo con KMS envelope encryption están protegidos

# MAL: heredar el rol del nodo EC2
# Si el nodo tiene un rol permisivo, TODOS los pods del nodo lo heredan
```

**La forma correcta es siempre IRSA** (sub-lab 02).
