# Lab 03.05 — Config Aggregator

> **Coste:** ~$0.003 por item agregado | **Prerrequisito:** lab 03.01 completado

---

## Objetivo

Crear un Config Aggregator para entender qué puede y qué NO puede hacer. Documentar el patrón correcto para remediación centralizada cross-account.

---

## Paso 1 — Crear Config Aggregator (single-account)

En este lab usamos un aggregator de cuenta única (sin Organizations). En producción, se usaría con Organizations para agregar datos de múltiples cuentas.

```bash
export AWS_REGION="eu-west-1"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws configservice put-configuration-aggregator \
  --configuration-aggregator-name "lab03-aggregator" \
  --account-aggregation-sources "[
    {
      \"AccountIds\": [\"${ACCOUNT_ID}\"],
      \"AllAwsRegions\": false,
      \"AwsRegions\": [\"eu-west-1\"]
    }
  ]" \
  --region "$AWS_REGION"

echo "Config Aggregator creado: lab03-aggregator"
```

---

## Paso 2 — Ver el estado del aggregator

```bash
aws configservice describe-configuration-aggregators \
  --configuration-aggregator-names "lab03-aggregator" \
  --region "$AWS_REGION" \
  --query 'ConfigurationAggregators[0].{Nombre:ConfigurationAggregatorName,CreadoEn:CreationTime}' \
  --output table
```

---

## Paso 3 — Consultar compliance agregada

```bash
# Ver resumen de compliance por regla (vista agregada)
aws configservice get-aggregate-compliance-details-by-config-rule \
  --configuration-aggregator-name "lab03-aggregator" \
  --config-rule-name "restricted-ssh" \
  --account-id "$ACCOUNT_ID" \
  --aws-region "$AWS_REGION" \
  --region "$AWS_REGION" \
  --query 'AggregateEvaluationResults[].{Recurso:EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId,Estado:ComplianceType,Cuenta:AccountId}' \
  --output table
```

```bash
# Ver compliance por cuenta (útil en multi-cuenta)
aws configservice get-aggregate-config-rule-compliance-summary \
  --configuration-aggregator-name "lab03-aggregator" \
  --filters AccountId="$ACCOUNT_ID" \
  --region "$AWS_REGION" \
  --query 'AggregateComplianceCounts[].{Cuenta:GroupName,Compliant:ComplianceSummary.CompliantResourceCount.CappedCount,NonCompliant:ComplianceSummary.NonCompliantResourceCount.CappedCount}' \
  --output table
```

---

## Qué PUEDE y qué NO PUEDE hacer el Aggregator

### Lo que PUEDE hacer

```bash
# ✅ Ver estado de compliance de múltiples cuentas
aws configservice get-aggregate-compliance-details-by-config-rule \
  --configuration-aggregator-name "lab03-aggregator" \
  --config-rule-name "restricted-ssh" \
  --account-id "$ACCOUNT_ID" \
  --aws-region "$AWS_REGION" \
  --region "$AWS_REGION"

# ✅ Ver historial de configuración de recursos en cuentas miembro
aws configservice batch-get-aggregate-resource-config \
  --configuration-aggregator-name "lab03-aggregator" \
  --resource-identifiers "[{\"SourceAccountId\":\"${ACCOUNT_ID}\",\"SourceRegion\":\"eu-west-1\",\"ResourceId\":\"vpc-xxx\",\"ResourceType\":\"AWS::EC2::VPC\"}]" \
  --region "$AWS_REGION"

# ✅ Ejecutar queries avanzadas sobre todos los recursos agregados
aws configservice select-aggregate-resource-config \
  --configuration-aggregator-name "lab03-aggregator" \
  --expression "SELECT resourceId, resourceType, configuration.state WHERE resourceType = 'AWS::EC2::SecurityGroup'" \
  --region "$AWS_REGION"
```

### Lo que NO PUEDE hacer

```
❌ El Aggregator NO puede ejecutar remediaciones cross-account directamente.
❌ El Aggregator NO puede modificar recursos en cuentas miembro.
❌ El Aggregator NO puede ejecutar SSM Automation en cuentas miembro.
```

---

## Patrón correcto de remediación centralizada cross-account

Para remediar recursos en múltiples cuentas desde una cuenta centralizada:

```
Cuenta Security (Aggregator):
  1. Config Aggregator detecta NON_COMPLIANT en cuenta Dev
  2. EventBridge Rule reacciona al finding del Aggregator
  3. Lambda en cuenta Security recibe el evento
  4. Lambda hace sts:AssumeRole hacia el RemediationRole en cuenta Dev
  5. Lambda ejecuta la remediación con los permisos del RemediationRole

Cuenta Dev:
  - IAM Role "RemediationRole" con trust policy que permite AssumeRole desde cuenta Security
  - Permisos: modificar SGs, añadir tags, etc.
```

```bash
# Ejemplo conceptual de la Lambda de remediación cross-account
cat <<'EOF'
import boto3

def lambda_handler(event, context):
    target_account = event['account_id']
    target_resource = event['resource_id']

    # AssumeRole en la cuenta destino
    sts = boto3.client('sts')
    assumed = sts.assume_role(
        RoleArn=f"arn:aws:iam::{target_account}:role/RemediationRole",
        RoleSessionName="CentralRemediation"
    )

    credentials = assumed['Credentials']

    # Usar las credenciales de la cuenta destino
    ec2 = boto3.client('ec2',
        region_name='eu-west-1',
        aws_access_key_id=credentials['AccessKeyId'],
        aws_secret_access_key=credentials['SecretAccessKey'],
        aws_session_token=credentials['SessionToken']
    )

    # Ejecutar remediación en la cuenta destino
    ec2.revoke_security_group_ingress(
        GroupId=target_resource,
        IpPermissions=[{'IpProtocol': 'tcp', 'FromPort': 22, 'ToPort': 22,
                        'IpRanges': [{'CidrIp': '0.0.0.0/0'}]}]
    )
EOF
```

---

## Paso 4 — Limpiar

```bash
aws configservice delete-configuration-aggregator \
  --configuration-aggregator-name "lab03-aggregator" \
  --region "$AWS_REGION"

echo "Aggregator eliminado"
```

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Puede el Aggregator remediar en otras cuentas? | **NO** — solo lectura |
| ¿Cómo remediar cross-account con Config? | EventBridge → Lambda → sts:AssumeRole → remediar |
| ¿Necesita Organizations? | No para single-account. Sí para agregar múltiples cuentas automáticamente |
