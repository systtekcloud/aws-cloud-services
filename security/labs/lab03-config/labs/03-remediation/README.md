# Lab 03.03 — Config Automatic Remediation

> **Coste:** ~$0.00025 por step de SSM Automation | **Prerrequisito:** lab 03.02 completado

---

## Objetivo

Configurar Automatic Remediation en la regla `restricted-ssh` usando el SSM Automation Document `AWS-DisablePublicAccessForSecurityGroup`. Verificar el flujo completo: crear SG con puerto 22 → Config detecta NON_COMPLIANT → Remediation se ejecuta automáticamente → SG queda COMPLIANT.

---

## Cómo funciona la Automatic Remediation

```
1. Config detecta SG con puerto 22 abierto → NON_COMPLIANT
2. Config invoca SSM Automation Document (AWS-DisablePublicAccessForSecurityGroup)
3. SSM elimina la regla de ingress del puerto 22
4. Config re-evalúa el SG → COMPLIANT
5. Config registra el cambio en el historial
```

---

## Paso 1 — Crear IAM Role para la remediation (SSM Automation)

SSM Automation necesita permisos para modificar Security Groups.

```bash
export AWS_REGION="eu-west-1"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REMEDIATION_ROLE="lab03-config-remediation-role"

cat > /tmp/ssm-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ssm.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
  --role-name "$REMEDIATION_ROLE" \
  --assume-role-policy-document file:///tmp/ssm-trust-policy.json

# Permisos para modificar SGs
cat > /tmp/remediation-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeSecurityGroups",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:AuthorizeSecurityGroupIngress"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "$REMEDIATION_ROLE" \
  --policy-name "lab03-remediation-sg-policy" \
  --policy-document file:///tmp/remediation-policy.json

REMEDIATION_ROLE_ARN=$(aws iam get-role \
  --role-name "$REMEDIATION_ROLE" \
  --query 'Role.Arn' --output text)

echo "Remediation Role ARN: $REMEDIATION_ROLE_ARN"
```

---

## Paso 2 — Configurar Automatic Remediation en restricted-ssh

```bash
aws configservice put-remediation-configurations \
  --remediation-configurations "[
    {
      \"ConfigRuleName\": \"restricted-ssh\",
      \"TargetType\": \"SSM_DOCUMENT\",
      \"TargetId\": \"AWS-DisablePublicAccessForSecurityGroup\",
      \"Parameters\": {
        \"GroupId\": {
          \"ResourceValue\": {
            \"Value\": \"RESOURCE_ID\"
          }
        },
        \"AutomationAssumeRole\": {
          \"StaticValue\": {
            \"Values\": [\"${REMEDIATION_ROLE_ARN}\"]
          }
        }
      },
      \"Automatic\": true,
      \"MaximumAutomaticAttempts\": 3,
      \"RetryAttemptSeconds\": 60
    }
  ]" \
  --region "$AWS_REGION"

echo "Automatic remediation configurada"
```

**Parámetros clave:**
- `Automatic: true` → remediación automática (no requiere intervención manual)
- `MaximumAutomaticAttempts: 3` → máximo 3 intentos
- `RetryAttemptSeconds: 60` → esperar 60s entre intentos
- `RESOURCE_ID` → Config reemplaza esto con el ID del recurso NON_COMPLIANT

---

## Paso 3 — Probar el flujo completo

### Crear un SG con puerto 22 abierto

```bash
DEFAULT_VPC=$(aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)

SG_ID=$(aws ec2 create-security-group \
  --group-name "lab03-sg-auto-remediation-test" \
  --description "Lab03: SG para probar remediation automática" \
  --vpc-id "$DEFAULT_VPC" \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp --port 22 --cidr 0.0.0.0/0

echo "SG creado con puerto 22 abierto: $SG_ID"
echo "Verificando reglas actuales..."
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output table
```

### Forzar evaluación de Config

```bash
aws configservice start-config-rules-evaluation \
  --config-rule-names restricted-ssh \
  --region "$AWS_REGION"

echo "Esperando detección NON_COMPLIANT y ejecución de remediation (~2 min)..."
sleep 90
```

### Verificar que la remediation actuó

```bash
# Ver el estado de compliance
aws configservice get-compliance-details-by-resource \
  --resource-type "AWS::EC2::SecurityGroup" \
  --resource-id "$SG_ID" \
  --region "$AWS_REGION" \
  --query 'EvaluationResults[].{Regla:EvaluationResultIdentifier.EvaluationResultQualifier.ConfigRuleName,Estado:ComplianceType}' \
  --output table

# Verificar que el puerto 22 fue eliminado del SG
echo "Reglas de ingress actuales del SG:"
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output table
```

Output esperado: tabla vacía (sin reglas de ingress) → la remediation eliminó la regla del puerto 22.

### Ver el historial de ejecuciones de remediation

```bash
aws configservice describe-remediation-execution-statuses \
  --config-rule-name restricted-ssh \
  --resource-keys "[{\"resourceType\":\"AWS::EC2::SecurityGroup\",\"resourceId\":\"${SG_ID}\"}]" \
  --region "$AWS_REGION" \
  --query 'RemediationExecutionStatuses[].{Estado:State,Inicio:InvocationTime,Fin:LastUpdatedTime}' \
  --output table
```

Output esperado:
```
----------------------------------------------------------
| DescribeRemediationExecutionStatuses                   |
+----------+--------------------+------------------------+
|  Estado  |  Inicio            |  Fin                   |
+----------+--------------------+------------------------+
|  SUCCEEDED| 2026-03-24T10:..  | 2026-03-24T10:...      |
+----------+--------------------+------------------------+
```

---

## Paso 4 — Limpiar

```bash
aws ec2 delete-security-group --group-id "$SG_ID"
```

---

## Diferencia crítica: Config Automatic Remediation vs EventBridge + Lambda

Ambos patrones son válidos para "remediar automáticamente" — el examen SAA-C03 puede preguntar cuál usar:

| Criterio | Config Automatic Remediation | EventBridge + Lambda |
|---------|------------------------------|---------------------|
| **Trigger** | NON_COMPLIANT en Config Rule | Cualquier evento AWS |
| **Acción** | SSM Automation Document | Lógica Lambda custom |
| **Retries** | Integrado (MaximumAutomaticAttempts) | Gestión propia |
| **Visibilidad** | En la consola de Config | En CloudWatch Logs |
| **Cuándo usarlo** | "Remediar automáticamente cuando una Config Rule falle" | "Reaccionar a cualquier evento" |

**Pista SAA-C03:** si el enunciado menciona "Config Rule" + "automáticamente" → Config Automatic Remediation. Si menciona "EventBridge" o "cualquier cambio" → EventBridge + Lambda.
