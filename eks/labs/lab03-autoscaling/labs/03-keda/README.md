# Sub-lab 03: KEDA — Kubernetes Event-Driven Autoscaling

## Objetivo

Instalar KEDA, crear un ScaledObject que escale un Deployment basado en el número de mensajes en una cola SQS, y observar el scale-to-zero.

---

## Por qué KEDA y no solo HPA

HPA escala basado en métricas de pods (CPU/memoria). Pero ¿qué pasa si la carga viene de una cola SQS?

```
SQS tiene 1000 mensajes → pero el pod que los procesa no tiene CPU alta
  porque simplemente aún no los ha empezado a procesar.
  → HPA no escala (CPU = 0%)
  → KEDA sí escala (ve los 1000 mensajes directamente en SQS)
```

**KEDA también puede escalar a 0** (HPA tiene mínimo 1). Si la cola está vacía, KEDA puede bajar a 0 pods.

---

## Paso 1: Instalar KEDA

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace

kubectl get pods -n keda
# NAME                                    READY   STATUS
# keda-operator-xxx                       1/1     Running
# keda-operator-metrics-apiserver-xxx     1/1     Running
```

## Paso 2: Crear la cola SQS y el rol IRSA para KEDA

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"

# Crear la cola SQS
QUEUE_URL=$(aws sqs create-queue \
  --queue-name keda-lab-queue \
  --region $REGION \
  --query 'QueueUrl' --output text)

QUEUE_ARN=$(aws sqs get-queue-attributes \
  --queue-url $QUEUE_URL \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' --output text)

# Crear el rol IRSA para KEDA (leer métricas de SQS)
cat > keda-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/$(aws eks describe-cluster --name eks-dev --query 'cluster.identity.oidc.issuer' --output text | cut -d'/' -f3-)" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.eks.eu-west-1.amazonaws.com/id/XXXXX:sub": "system:serviceaccount:keda:keda-operator"
      }
    }
  }]
}
EOF

aws iam create-role --role-name keda-sqs-reader --assume-role-policy-document file://keda-trust.json
aws iam put-role-policy --role-name keda-sqs-reader --policy-name sqs-read --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Action\": [\"sqs:GetQueueAttributes\", \"sqs:GetQueueUrl\"],
    \"Resource\": \"${QUEUE_ARN}\"
  }]
}"

# Anotar el ServiceAccount de KEDA
kubectl annotate serviceaccount keda-operator -n keda \
  eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/keda-sqs-reader
```

## Paso 3: Desplegar el worker y configurar ScaledObject

```bash
# Worker que procesa mensajes de SQS
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sqs-worker
  namespace: workloads
spec:
  replicas: 0  # KEDA gestiona las réplicas, empezamos en 0
  selector:
    matchLabels:
      app: sqs-worker
  template:
    metadata:
      labels:
        app: sqs-worker
    spec:
      containers:
      - name: worker
        image: amazon/aws-cli:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          while true; do
            MSG=$(aws sqs receive-message --queue-url $QUEUE_URL --max-number-of-messages 1 --output json)
            if [ -n "$(echo $MSG | jq '.Messages')" ]; then
              echo "Procesando: $(echo $MSG | jq -r '.Messages[0].Body')"
              RECEIPT=$(echo $MSG | jq -r '.Messages[0].ReceiptHandle')
              aws sqs delete-message --queue-url $QUEUE_URL --receipt-handle "$RECEIPT"
              sleep 2
            else
              sleep 5
            fi
          done
        env:
        - name: QUEUE_URL
          value: "${QUEUE_URL}"
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
---
# ScaledObject: define cómo KEDA escala el Deployment
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: sqs-scaledobject
  namespace: workloads
spec:
  scaleTargetRef:
    name: sqs-worker
  minReplicaCount: 0      # scale to zero cuando cola vacía
  maxReplicaCount: 20
  pollingInterval: 30     # comprobar SQS cada 30 segundos
  cooldownPeriod: 60      # esperar 60s antes de scale-down
  triggers:
  - type: aws-sqs-queue
    metadata:
      queueURL: "${QUEUE_URL}"
      queueLength: "5"    # 1 pod por cada 5 mensajes
      awsRegion: "${REGION}"
    authenticationRef:
      name: keda-sqs-auth
---
# TriggerAuthentication: cómo autenticarse en AWS (IRSA)
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: keda-sqs-auth
  namespace: workloads
spec:
  podIdentity:
    provider: aws
EOF
```

## Paso 4: Enviar mensajes para disparar el scale-up

```bash
# Enviar 50 mensajes a la cola
for i in $(seq 1 50); do
  aws sqs send-message \
    --queue-url $QUEUE_URL \
    --message-body "Mensaje $i — $(date)" \
    --region $REGION
done

# Observar el scale-up (KEDA revisa cada 30s)
# 50 mensajes ÷ 5 msgs/pod = 10 pods
watch kubectl get deployment sqs-worker -n workloads
# READY   UP-TO-DATE   AVAILABLE
# 0/0     0            0          ← sin mensajes inicialmente
# 0/10    10           0          ← KEDA escala a 10
# 10/10   10           10         ← workers procesando

# Ver el ScaledObject
kubectl get scaledobject sqs-worker -n workloads
# NAME              SCALETARGETKIND   READY   ACTIVE   FALLBACK   PAUSED
# sqs-scaledobject  Deployment        True    True     False      False
```

## Paso 5: Scale to zero

```bash
# Cuando los workers procesen todos los mensajes, KEDA baja a 0
# Verificar que la cola está vacía
aws sqs get-queue-attributes \
  --queue-url $QUEUE_URL \
  --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes.ApproximateNumberOfMessages'

# Ver el scale-down a 0
kubectl get deployment sqs-worker -n workloads -w
# READY   UP-TO-DATE   AVAILABLE
# 2/2     2            2          ← últimos workers
# 0/0     0            0          ← scale to zero (cooldownPeriod=60s)
```

## Limpieza

```bash
aws sqs delete-queue --queue-url $QUEUE_URL
aws iam delete-role-policy --role-name keda-sqs-reader --policy-name sqs-read
aws iam delete-role --role-name keda-sqs-reader
helm uninstall keda -n keda
kubectl delete namespace keda
```
