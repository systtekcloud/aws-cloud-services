# Sub-lab 02: IRSA — IAM Roles for Service Accounts

## Objetivo

Configurar IRSA para que un pod pueda leer de S3 sin credenciales en el código ni en variables de entorno.

---

## Por qué IRSA (y no las alternativas)

```bash
# MAL: credenciales en el pod
kubectl create secret generic aws-creds \
  --from-literal=AWS_ACCESS_KEY_ID=AKIA... \
  --from-literal=AWS_SECRET_ACCESS_KEY=...
# → Credenciales estáticas que no rotan, visibles en el manifest

# TAMBIÉN MAL: rol del nodo EC2
# Todos los pods del nodo comparten el mismo rol del nodo
# Si hay 100 pods en el nodo, todos tienen los mismos permisos

# BIEN: IRSA
# Cada ServiceAccount tiene su propio rol IAM
# Los permisos son fine-grained por aplicación
# Las credenciales rotan automáticamente (STS, tokens de 1h)
```

---

## Paso 1: Verificar el OIDC Provider

```bash
# El OIDC Provider se crea con el cluster (o manualmente)
aws iam list-open-id-connect-providers

# Obtener el OIDC issuer del cluster
OIDC_ISSUER=$(aws eks describe-cluster \
  --name eks-lab \
  --query "cluster.identity.oidc.issuer" \
  --output text)

echo $OIDC_ISSUER
# https://oidc.eks.eu-west-1.amazonaws.com/id/XXXXXXXXXXXXXXXX

# Si no existe el OIDC Provider, crearlo:
eksctl utils associate-iam-oidc-provider \
  --cluster eks-lab \
  --approve
```

## Paso 2: Crear el bucket S3 de prueba

```bash
BUCKET_NAME="irsa-lab-$(aws sts get-caller-identity --query Account --output text)"
aws s3 mb s3://$BUCKET_NAME --region eu-west-1

# Subir un fichero de prueba
echo "Hola desde IRSA" | aws s3 cp - s3://$BUCKET_NAME/test.txt
```

## Paso 3: Crear el rol IAM con trust policy para EKS

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_ID=$(echo $OIDC_ISSUER | cut -d'/' -f5)

# Crear trust policy
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/${OIDC_ID}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.eks.eu-west-1.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com",
        "oidc.eks.eu-west-1.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:lab:s3-reader"
      }
    }
  }]
}
EOF

# Crear el rol
aws iam create-role \
  --role-name eks-s3-reader \
  --assume-role-policy-document file://trust-policy.json

# Adjuntar política de S3 read-only
aws iam put-role-policy \
  --role-name eks-s3-reader \
  --policy-name s3-read \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [\"s3:GetObject\", \"s3:ListBucket\"],
      \"Resource\": [
        \"arn:aws:s3:::${BUCKET_NAME}\",
        \"arn:aws:s3:::${BUCKET_NAME}/*\"
      ]
    }]
  }"
```

## Paso 4: Crear ServiceAccount con anotación IRSA

```bash
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/eks-s3-reader"

# Crear ServiceAccount con la anotación del rol
kubectl create serviceaccount s3-reader -n lab

kubectl annotate serviceaccount s3-reader -n lab \
  eks.amazonaws.com/role-arn=$ROLE_ARN

# Verificar la anotación
kubectl describe serviceaccount s3-reader -n lab
# Annotations: eks.amazonaws.com/role-arn: arn:aws:iam::...
```

## Paso 5: Desplegar pod que usa IRSA

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: s3-test
  namespace: lab
spec:
  serviceAccountName: s3-reader  # ← usa el ServiceAccount con IRSA
  containers:
  - name: aws-cli
    image: amazon/aws-cli:latest
    command: ["sleep", "3600"]
    env:
    - name: AWS_DEFAULT_REGION
      value: eu-west-1
EOF

# Esperar a que el pod esté running
kubectl wait pod s3-test -n lab --for=condition=Ready --timeout=120s

# Verificar que el pod puede leer S3
kubectl exec -n lab s3-test -- aws s3 ls s3://$BUCKET_NAME
# 2026-04-10 10:00:00       17 test.txt

kubectl exec -n lab s3-test -- aws s3 cp s3://$BUCKET_NAME/test.txt -
# Hola desde IRSA

# Verificar qué rol está usando el pod
kubectl exec -n lab s3-test -- aws sts get-caller-identity
# {
#   "Account": "123456789",
#   "Arn": "arn:aws:sts::123456789:assumed-role/eks-s3-reader/...",
#   "UserId": "AROA..."
# }
```

## Paso 6: Verificar que el pod NO puede escribir en S3

```bash
# Intentar escribir (debe fallar — el rol solo tiene permisos de lectura)
kubectl exec -n lab s3-test -- aws s3 cp /etc/hostname s3://$BUCKET_NAME/test-write.txt
# upload failed: /etc/hostname to s3://...: An error occurred (AccessDenied)

echo "✓ Least privilege funcionando correctamente"
```

## Cómo funciona internamente

```
1. Pod creado con serviceAccountName: s3-reader
   ↓
2. EKS inyecta automáticamente en el pod:
   - AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
   - AWS_ROLE_ARN=arn:aws:iam::...:role/eks-s3-reader
   ↓
3. SDK de AWS detecta estas variables → llama a STS AssumeRoleWithWebIdentity
   ↓
4. STS valida el token JWT con el OIDC Provider de EKS
   ↓
5. STS devuelve credenciales temporales (1 hora)
   ↓
6. SDK usa esas credenciales para S3, DynamoDB, etc.
```

## Limpieza del sub-lab

```bash
kubectl delete pod s3-test -n lab
kubectl delete serviceaccount s3-reader -n lab
aws iam delete-role-policy --role-name eks-s3-reader --policy-name s3-read
aws iam delete-role --role-name eks-s3-reader
aws s3 rm s3://$BUCKET_NAME --recursive
aws s3 rb s3://$BUCKET_NAME
```
