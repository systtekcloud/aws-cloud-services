# Sub-lab 01: IRSA Avanzado — Session Tags y Auditoría

## Objetivo

Usar session tags en IRSA para pasar metadata del pod (namespace, service account, cluster) como tags de sesión STS. Esto permite auditoría granular en CloudTrail y políticas IAM basadas en tags.

---

## Por qué session tags

Con IRSA básico, CloudTrail muestra:
```
assumed-role/mi-rol/pod-xyz
```

Con session tags, CloudTrail muestra:
```
assumed-role/mi-rol/pod-xyz
  + SessionTags: {namespace=produccion, serviceaccount=api-service, cluster=eks-prod}
```

Esto permite:
- **Auditoría granular:** saber exactamente qué pod hizo qué en DynamoDB
- **Políticas basadas en tags:** solo los pods del namespace "produccion" pueden escribir en DynamoDB

---

## Paso 1: Configurar session tags en la trust policy

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_ID=$(aws eks describe-cluster --name eks-dev --query 'cluster.identity.oidc.issuer' --output text | cut -d'/' -f5)

# Trust policy con session tags + condición de namespace
cat > trust-policy-advanced.json <<EOF
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
        "oidc.eks.eu-west-1.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "oidc.eks.eu-west-1.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:produccion:*"
      }
    }
  }]
}
EOF

# Crear el rol con la trust policy
aws iam create-role \
  --role-name eks-produccion-dynamo \
  --assume-role-policy-document file://trust-policy-advanced.json

# Política IAM que solo permite escribir si el tag de namespace es "produccion"
aws iam put-role-policy \
  --role-name eks-produccion-dynamo \
  --policy-name dynamodb-write \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["dynamodb:PutItem", "dynamodb:UpdateItem"],
      "Resource": "arn:aws:dynamodb:eu-west-1:*:table/app-data",
      "Condition": {
        "StringEquals": {
          "aws:PrincipalTag/kubernetes-namespace": "produccion"
        }
      }
    }]
  }'
```

## Paso 2: EKS pasa automáticamente los session tags

Cuando un pod usa IRSA con la anotación correcta, EKS inyecta automáticamente en el token JWT los claims:
- `kubernetes.io/namespace` → namespace del pod
- `kubernetes.io/serviceaccount/name` → nombre del ServiceAccount
- `kubernetes.io/pod/name` → nombre del pod

STS convierte estos claims en session tags al hacer `AssumeRoleWithWebIdentity`.

```bash
# Crear namespace y ServiceAccount
kubectl create namespace produccion

kubectl create serviceaccount api-service -n produccion

kubectl annotate serviceaccount api-service -n produccion \
  eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/eks-produccion-dynamo

# Desplegar pod de prueba
kubectl run test-dynamo \
  --image=amazon/aws-cli \
  --namespace=produccion \
  --serviceaccount=api-service \
  --restart=Never \
  -- sleep 3600

# Verificar los session tags en el token
kubectl exec test-dynamo -n produccion -- \
  aws sts get-caller-identity
# {
#   "Arn": "arn:aws:sts::...:assumed-role/eks-produccion-dynamo/...",
#   "Account": "..."
# }

# Ver los session tags (en CloudTrail → buscar AssumeRoleWithWebIdentity)
```

## Paso 3: Buscar en CloudTrail

```bash
# Buscar eventos IRSA en los últimos 5 minutos
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --query 'Events[].{Time:EventTime,User:Username,Role:Resources[0].ResourceName}'

# El evento incluye los session tags en requestParameters.webIdentityToken
```

## Limpieza

```bash
kubectl delete pod test-dynamo -n produccion
kubectl delete namespace produccion
aws iam delete-role-policy --role-name eks-produccion-dynamo --policy-name dynamodb-write
aws iam delete-role --role-name eks-produccion-dynamo
```
