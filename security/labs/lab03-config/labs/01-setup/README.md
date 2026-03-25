# Lab 03.01 — Habilitar AWS Config

> **Coste:** ~$0.50 por hora de lab | **Región:** eu-west-1 | **Duración:** ~20 minutos

---

## Objetivo

Habilitar AWS Config con un delivery channel a S3, configurar el IAM Role necesario, y verificar que Config empieza a registrar recursos.

---

## Paso 1 — Variables de entorno

```bash
export AWS_REGION="eu-west-1"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CONFIG_BUCKET="lab03-config-delivery-${ACCOUNT_ID}"
export CONFIG_ROLE="lab03-config-recorder-role"

echo "Account ID: $ACCOUNT_ID"
```

---

## Paso 2 — Crear bucket S3 para el delivery channel

Config necesita un bucket S3 para almacenar snapshots de configuración y el historial de cambios.

```bash
aws s3api create-bucket \
  --bucket "$CONFIG_BUCKET" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

# Habilitar versionado (recomendado para el historial)
aws s3api put-bucket-versioning \
  --bucket "$CONFIG_BUCKET" \
  --versioning-configuration Status=Enabled

echo "Bucket creado: $CONFIG_BUCKET"
```

---

## Paso 3 — Crear IAM Role para Config

```bash
# Trust policy: permite a Config asumir este rol
cat > /tmp/config-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "config.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
  --role-name "$CONFIG_ROLE" \
  --assume-role-policy-document file:///tmp/config-trust-policy.json

# Adjuntar política gestionada de AWS para Config
aws iam attach-role-policy \
  --role-name "$CONFIG_ROLE" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"

CONFIG_ROLE_ARN=$(aws iam get-role \
  --role-name "$CONFIG_ROLE" \
  --query 'Role.Arn' --output text)

echo "IAM Role ARN: $CONFIG_ROLE_ARN"
```

---

## Paso 4 — Habilitar Config Recorder

```bash
# Crear el configuration recorder (graba todos los recursos soportados)
aws configservice put-configuration-recorder \
  --configuration-recorder name=default,roleARN="$CONFIG_ROLE_ARN" \
  --recording-group allSupported=true,includeGlobalResourceTypes=true \
  --region "$AWS_REGION"

echo "Configuration recorder configurado"
```

---

## Paso 5 — Crear el delivery channel

```bash
# Bucket policy requerida por Config
cat > /tmp/config-bucket-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AWSConfigBucketPermissionsCheck",
      "Effect": "Allow",
      "Principal": {"Service": "config.amazonaws.com"},
      "Action": "s3:GetBucketAcl",
      "Resource": "arn:aws:s3:::${CONFIG_BUCKET}"
    },
    {
      "Sid": "AWSConfigBucketDelivery",
      "Effect": "Allow",
      "Principal": {"Service": "config.amazonaws.com"},
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::${CONFIG_BUCKET}/AWSLogs/${ACCOUNT_ID}/Config/*",
      "Condition": {
        "StringEquals": {"s3:x-amz-acl": "bucket-owner-full-control"}
      }
    }
  ]
}
EOF

aws s3api put-bucket-policy \
  --bucket "$CONFIG_BUCKET" \
  --policy file:///tmp/config-bucket-policy.json

# Crear el delivery channel
aws configservice put-delivery-channel \
  --delivery-channel name=default,s3BucketName="$CONFIG_BUCKET" \
  --region "$AWS_REGION"

echo "Delivery channel configurado"
```

---

## Paso 6 — Iniciar el recorder

```bash
aws configservice start-configuration-recorder \
  --configuration-recorder-name default \
  --region "$AWS_REGION"

echo "Config recorder iniciado"
```

---

## Paso 7 — Verificar que Config está grabando

```bash
aws configservice describe-configuration-recorder-status \
  --region "$AWS_REGION" \
  --query 'ConfigurationRecordersStatus[0].{Nombre:name,Grabando:recording,UltimoEstado:lastStatus}' \
  --output table
```

Output esperado:
```
-----------------------------------------------
|   DescribeConfigurationRecorderStatus        |
+-------------+----------+--------------------+
|   Nombre    | Grabando | UltimoEstado       |
+-------------+----------+--------------------+
|   default   |  True    |  SUCCESS           |
+-------------+----------+--------------------+
```

---

## Paso 8 — Explorar el historial de un recurso existente

```bash
# Ver el historial de configuración de la VPC por defecto
DEFAULT_VPC=$(aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)

echo "VPC por defecto: $DEFAULT_VPC"

# Puede tardar 1-2 minutos en aparecer en Config
sleep 60

aws configservice get-resource-config-history \
  --resource-type AWS::EC2::VPC \
  --resource-id "$DEFAULT_VPC" \
  --region "$AWS_REGION" \
  --query 'configurationItems[0].{Tipo:resourceType,ID:resourceId,Estado:configurationItemStatus,Fecha:configurationItemCaptureTime}' \
  --output table
```

---

## validate.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

REGION="eu-west-1"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

echo "=== Lab 03.01 — AWS Config Setup ==="

STATUS=$(aws configservice describe-configuration-recorder-status \
  --region "$REGION" \
  --query 'ConfigurationRecordersStatus[0].recording' \
  --output text 2>/dev/null || echo "false")

if [[ "$STATUS" == "True" ]]; then
  pass "Config recorder está activo y grabando"
else
  fail "Config recorder no está grabando (status: $STATUS)"
fi

CHANNEL=$(aws configservice describe-delivery-channels \
  --region "$REGION" \
  --query 'DeliveryChannels[0].name' \
  --output text 2>/dev/null || echo "NONE")

if [[ "$CHANNEL" != "NONE" ]]; then
  pass "Delivery channel configurado: $CHANNEL"
else
  fail "No hay delivery channel configurado"
fi

echo "Coste aproximado: \$0.003 por item de configuración registrado"
```
