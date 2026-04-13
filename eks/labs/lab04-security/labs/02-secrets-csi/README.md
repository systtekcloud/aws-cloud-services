# Sub-lab 02: Secrets Store CSI Driver

## Objetivo

Montar secrets de AWS Secrets Manager directamente como ficheros en el pod. Sin kubernetes Secrets, sin variables de entorno con secretos en texto plano.

---

## Por qué CSI Driver y no Kubernetes Secrets

| Enfoque | Almacenamiento | Rotación | Auditoría |
|---------|---------------|----------|-----------|
| Variable de entorno | En el pod (texto plano) | Manual | Ninguna |
| Kubernetes Secret | etcd (Base64, no cifrado por defecto) | Manual | Básica |
| CSI Driver + Secrets Manager | AWS (cifrado KMS) | Automática | CloudTrail |

Con CSI Driver: el secreto nunca pasa por etcd. Se monta directamente de Secrets Manager como fichero en el pod.

---

## Paso 1: Crear el secreto en AWS Secrets Manager

```bash
# Crear un secreto con múltiples claves
aws secretsmanager create-secret \
  --name eks-lab/db-credentials \
  --secret-string '{"username":"app_user","password":"SuperSecreta123!","host":"db.internal","port":"5432"}'

echo "Secreto creado en Secrets Manager"
```

## Paso 2: Instalar Secrets Store CSI Driver y AWS Provider

```bash
# Instalar el driver CSI
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace kube-system \
  --set syncSecret.enabled=true  # sincronizar como Kubernetes Secret también (opcional)

# Instalar el provider de AWS
kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml

kubectl get pods -n kube-system | grep -E "csi|secrets"
```

## Paso 3: Crear el rol IRSA para leer el secreto

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_ID=$(aws eks describe-cluster --name eks-dev --query 'cluster.identity.oidc.issuer' --output text | cut -d'/' -f5)

aws iam create-role \
  --role-name eks-secrets-reader \
  --assume-role-policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": { \"Federated\": \"arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/${OIDC_ID}\" },
      \"Action\": \"sts:AssumeRoleWithWebIdentity\",
      \"Condition\": { \"StringEquals\": {
        \"oidc.eks.eu-west-1.amazonaws.com/id/${OIDC_ID}:sub\": \"system:serviceaccount:workloads:secrets-reader-sa\"
      }}
    }]
  }"

aws iam put-role-policy \
  --role-name eks-secrets-reader \
  --policy-name read-secret \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [\"secretsmanager:GetSecretValue\", \"secretsmanager:DescribeSecret\"],
      \"Resource\": \"arn:aws:secretsmanager:eu-west-1:${ACCOUNT_ID}:secret:eks-lab/db-credentials*\"
    }]
  }"

kubectl create serviceaccount secrets-reader-sa -n workloads
kubectl annotate serviceaccount secrets-reader-sa -n workloads \
  eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/eks-secrets-reader
```

## Paso 4: SecretProviderClass y Pod

```bash
cat <<EOF | kubectl apply -f -
# SecretProviderClass: define qué secretos montar y cómo
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: db-credentials
  namespace: workloads
spec:
  provider: aws
  parameters:
    objects: |
      - objectName: "eks-lab/db-credentials"
        objectType: "secretsmanager"
        jmesPath:
          - path: "username"
            objectAlias: "db-username"
          - path: "password"
            objectAlias: "db-password"
          - path: "host"
            objectAlias: "db-host"
---
# Pod que monta el secreto
apiVersion: v1
kind: Pod
metadata:
  name: secrets-test
  namespace: workloads
spec:
  serviceAccountName: secrets-reader-sa
  volumes:
  - name: secrets-store
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: db-credentials
  containers:
  - name: app
    image: nginx:1.27-alpine
    volumeMounts:
    - name: secrets-store
      mountPath: /mnt/secrets
      readOnly: true
EOF

# Esperar a que el pod esté Running
kubectl wait pod secrets-test -n workloads --for=condition=Ready --timeout=120s

# Verificar que los ficheros están montados
kubectl exec secrets-test -n workloads -- ls /mnt/secrets/
# db-host  db-password  db-username

kubectl exec secrets-test -n workloads -- cat /mnt/secrets/db-username
# app_user

# El secreto no está en el env ni en etcd — solo accesible como fichero
kubectl exec secrets-test -n workloads -- env | grep -i "password"
# (vacío — el secret no está en variables de entorno)
```

## Paso 5: Rotación automática

```bash
# Rotar el secreto en Secrets Manager
aws secretsmanager update-secret \
  --secret-id eks-lab/db-credentials \
  --secret-string '{"username":"app_user","password":"NuevaContraseña456!","host":"db.internal","port":"5432"}'

# El CSI Driver refresca el montaje periódicamente (por defecto: 2 minutos)
# Después de ~2 min, el fichero en el pod contiene el nuevo valor
sleep 120
kubectl exec secrets-test -n workloads -- cat /mnt/secrets/db-password
# NuevaContraseña456!  ← actualizado sin restart del pod
```
