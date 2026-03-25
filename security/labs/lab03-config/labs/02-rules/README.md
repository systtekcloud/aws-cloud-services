# Lab 03.02 — Config Rules y compliance

> **Coste:** ~$0.001 por evaluación | **Prerrequisito:** lab 03.01 completado

---

## Objetivo

Añadir managed rules para detectar Security Groups con puerto 22 abierto y buckets S3 públicos. Crear recursos que violen las reglas y verificar que Config los marca como `NON_COMPLIANT`.

---

## Regla 1 — `restricted-ssh`: puerto 22 no abierto a internet

### Crear la regla

```bash
export AWS_REGION="eu-west-1"

aws configservice put-config-rule \
  --config-rule '{
    "ConfigRuleName": "restricted-ssh",
    "Description": "Verifica que los Security Groups no permiten puerto 22 desde 0.0.0.0/0",
    "Source": {
      "Owner": "AWS",
      "SourceIdentifier": "INCOMING_SSH_DISABLED"
    },
    "Scope": {
      "ComplianceResourceTypes": ["AWS::EC2::SecurityGroup"]
    }
  }' \
  --region "$AWS_REGION"

echo "Regla restricted-ssh creada"
```

### Crear un Security Group que viola la regla

```bash
DEFAULT_VPC=$(aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)

SG_ID=$(aws ec2 create-security-group \
  --group-name "lab03-sg-open-ssh" \
  --description "Lab03: SG con puerto 22 abierto - viola restricted-ssh" \
  --vpc-id "$DEFAULT_VPC" \
  --query 'GroupId' --output text)

# Abrir puerto 22 a internet
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0

echo "Security Group creado: $SG_ID (puerto 22 abierto a internet)"
```

### Forzar evaluación y ver el resultado

```bash
# Forzar evaluación inmediata
aws configservice start-config-rules-evaluation \
  --config-rule-names restricted-ssh \
  --region "$AWS_REGION"

echo "Esperando evaluación (~30s)..."
sleep 30

# Ver compliance del Security Group
aws configservice get-compliance-details-by-resource \
  --resource-type "AWS::EC2::SecurityGroup" \
  --resource-id "$SG_ID" \
  --region "$AWS_REGION" \
  --query 'EvaluationResults[].{Regla:EvaluationResultIdentifier.EvaluationResultQualifier.ConfigRuleName,Estado:ComplianceType}' \
  --output table
```

Output esperado:
```
-------------------------------------------
|  GetComplianceDetailsByResource          |
+----------------+-------------------------+
|  Regla         | Estado                  |
+----------------+-------------------------+
|  restricted-ssh| NON_COMPLIANT           |
+----------------+-------------------------+
```

---

## Regla 2 — `s3-bucket-public-read-prohibited`

### Crear la regla

```bash
aws configservice put-config-rule \
  --config-rule '{
    "ConfigRuleName": "s3-bucket-public-read-prohibited",
    "Description": "Verifica que los buckets S3 no permiten lectura pública",
    "Source": {
      "Owner": "AWS",
      "SourceIdentifier": "S3_BUCKET_PUBLIC_READ_PROHIBITED"
    },
    "Scope": {
      "ComplianceResourceTypes": ["AWS::S3::Bucket"]
    }
  }' \
  --region "$AWS_REGION"

echo "Regla s3-bucket-public-read-prohibited creada"
```

### Crear bucket público que viola la regla

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
PUBLIC_BUCKET="lab03-public-bucket-${ACCOUNT_ID}"

aws s3api create-bucket \
  --bucket "$PUBLIC_BUCKET" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

# Desactivar BPA y añadir policy pública
aws s3api put-public-access-block \
  --bucket "$PUBLIC_BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false

cat > /tmp/public-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${PUBLIC_BUCKET}/*"
  }]
}
EOF

aws s3api put-bucket-policy --bucket "$PUBLIC_BUCKET" --policy file:///tmp/public-policy.json

echo "Bucket público creado: $PUBLIC_BUCKET"

# Forzar evaluación
aws configservice start-config-rules-evaluation \
  --config-rule-names s3-bucket-public-read-prohibited \
  --region "$AWS_REGION"

sleep 30

# Ver compliance
aws configservice get-compliance-details-by-resource \
  --resource-type "AWS::S3::Bucket" \
  --resource-id "$PUBLIC_BUCKET" \
  --region "$AWS_REGION" \
  --query 'EvaluationResults[].{Regla:EvaluationResultIdentifier.EvaluationResultQualifier.ConfigRuleName,Estado:ComplianceType}' \
  --output table
```

---

## Ver el timeline de compliance de un recurso

Una de las funcionalidades más útiles de Config: ver el historial de compliance de un recurso.

```bash
# Ver la línea temporal del Security Group
aws configservice get-resource-config-history \
  --resource-type "AWS::EC2::SecurityGroup" \
  --resource-id "$SG_ID" \
  --region "$AWS_REGION" \
  --limit 5 \
  --query 'configurationItems[].{Fecha:configurationItemCaptureTime,Estado:configurationItemStatus}' \
  --output table
```

```bash
# Ver resumen de compliance por regla
aws configservice describe-compliance-by-config-rule \
  --region "$AWS_REGION" \
  --query 'ComplianceByConfigRules[].{Regla:ConfigRuleName,Estado:Compliance.ComplianceType}' \
  --output table
```

---

## Limpiar recursos no conformes (manual, antes de configurar remediation en lab03)

```bash
# Eliminar SG (después quitamos la regla de ingress)
aws ec2 revoke-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 delete-security-group --group-id "$SG_ID"

# Eliminar bucket público
aws s3 rb "s3://${PUBLIC_BUCKET}" --force
```

> En el lab 03.03 veremos cómo la remediation automática hace esto sin intervención manual.
