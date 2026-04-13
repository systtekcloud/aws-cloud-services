# Sub-lab 02: Karpenter — Node Provisioning

## Objetivo

Instalar Karpenter, configurar un NodePool, observar cómo provisiona nodos EC2 cuando hay pods pendientes, y entender la consolidación automática.

---

## Karpenter vs Cluster Autoscaler

| Criterio | Cluster Autoscaler | Karpenter |
|----------|-------------------|-----------|
| Configuración | Node Groups predefinidos | NodePool flexible |
| Velocidad | 3-5 min (lanza instancia via ASG) | <2 min (lanza directo) |
| Diversidad de instancias | Limitada al Node Group | Elige el mejor tipo de instancia |
| Consolidación | Básica | Inteligente (mueve pods, termina nodos) |
| Spot handling | Manual con spot grupos | Automático con interruption handling |

---

## Paso 1: Instalar Karpenter via Helm

```bash
# Variables del cluster
CLUSTER_NAME="eks-dev"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"

# Crear el rol IRSA para Karpenter
eksctl create iamserviceaccount \
  --cluster $CLUSTER_NAME \
  --namespace karpenter \
  --name karpenter \
  --attach-policy-arn arn:aws:iam::$ACCOUNT_ID:policy/KarpenterControllerPolicy \
  --approve

# Instalar Karpenter
helm repo add karpenter https://charts.karpenter.sh/
helm install karpenter karpenter/karpenter \
  --namespace karpenter \
  --create-namespace \
  --set settings.clusterName=$CLUSTER_NAME \
  --set settings.interruptionQueue=karpenter-interruption-$CLUSTER_NAME \
  --set controller.resources.requests.cpu=100m \
  --set controller.resources.requests.memory=256Mi

kubectl get pods -n karpenter
# NAME                        READY   STATUS    RESTARTS
# karpenter-xxx-yyy           1/1     Running   0
```

## Paso 2: Configurar NodePool y EC2NodeClass

```bash
cat <<'EOF' | kubectl apply -f -
# EC2NodeClass: define cómo son los nodos EC2
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiSelectorTerms:
  - alias: al2023@latest   # Amazon Linux 2023 (latest compatible con EKS)
  role: KarpenterNodeRole  # IAM role para los nodos
  subnetSelectorTerms:
  - tags:
      karpenter.sh/discovery: eks-dev   # subnets privadas con este tag
  securityGroupSelectorTerms:
  - tags:
      karpenter.sh/discovery: eks-dev
---
# NodePool: define las constraints de los nodos que Karpenter puede provisionar
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
      - key: kubernetes.io/arch
        operator: In
        values: ["amd64"]
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["spot", "on-demand"]  # preferir Spot, fallback a On-Demand
      - key: node.kubernetes.io/instance-type
        operator: In
        values: ["m5.large", "m5.xlarge", "m5.2xlarge", "m6i.large", "m6i.xlarge"]
  limits:
    cpu: 100     # máximo 100 vCPU en este NodePool
    memory: 400Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s   # en lab: 30s (en prod: 1m-5m)
EOF
```

## Paso 3: Crear pods que necesitan nodos

```bash
# Deployment que necesita más recursos de los disponibles en Fargate
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inflated
  namespace: workloads
spec:
  replicas: 5
  selector:
    matchLabels:
      app: inflated
  template:
    metadata:
      labels:
        app: inflated
    spec:
      # Forzar que vaya a nodos EC2 de Karpenter (no Fargate)
      nodeSelector:
        karpenter.sh/nodepool: default
      containers:
      - name: pause
        image: public.ecr.aws/eks-distro/kubernetes/pause:latest
        resources:
          requests:
            cpu: "1"      # 1 vCPU por pod
            memory: "1Gi"
EOF

# Observar que Karpenter provisiona nodos
kubectl get nodes -w
# NAME                                          STATUS     ROLES    AGE
# fargate-ip-10-30-x-x.compute.internal        Ready      <none>   5m
# ip-10-30-0-x.eu-west-1.compute.internal      NotReady   <none>   5s   ← Karpenter!
# ip-10-30-0-x.eu-west-1.compute.internal      Ready      <none>   90s

# Ver logs de Karpenter
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -c controller | grep -E "launched|scheduled"
```

## Paso 4: Observar la consolidación

```bash
# Escalar el Deployment a 0 → Karpenter debería terminar los nodos vacíos
kubectl scale deployment inflated -n workloads --replicas=0

# Con consolidationPolicy=WhenEmptyOrUnderutilized + consolidateAfter=30s:
# Karpenter detecta nodo vacío → lanza "cordon + drain" → termina instancia
kubectl get nodes -w
# ip-10-30-0-x.eu-west-1.compute.internal   Ready      <none>   5m   ← vacío
# ip-10-30-0-x.eu-west-1.compute.internal   Ready,SchedulingDisabled   ← cordon
# (nodo desaparece en <1 min)

# Ver eventos de consolidación
kubectl get events -n karpenter | grep -i "consolid"
```

## Paso 5: Interruption handling (Spot)

Cuando AWS va a interrumpir una instancia Spot (aviso de 2 minutos):

```
AWS → EC2 Spot Interruption Notice (SQS queue)
  ↓
Karpenter detecta el mensaje en SQS (polling cada 1s)
  ↓
Karpenter hace cordon + drain del nodo (2 min disponibles)
  ↓
Pods rescheduleados en otro nodo (On-Demand si no hay Spot disponible)
  ↓
AWS termina la instancia Spot
```

**Configurar la cola SQS de interrupciones:**
```bash
# La cola se crea como parte de la instalación de Karpenter (CloudFormation)
# El nombre es: karpenter-interruption-{cluster-name}
aws sqs list-queues | grep karpenter
```
