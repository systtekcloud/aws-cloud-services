# Cleanup — Security & Governance Lab

> ⚠️ **Orden crítico:** seguir exactamente este orden para evitar errores de dependencias.
> Ejecutar desde la **Management Account** salvo donde se indique la cuenta específica.

---

## Estimación de costes residuales si NO se hace cleanup

| Recurso | Coste/mes si se deja activo |
|---------|---------------------------|
| KMS CMK (lab-app-secrets) | $1.00/mes |
| KMS CMK (lab-log-archive) | $1.00/mes |
| Secrets Manager (lab/db/credentials) | $0.40/mes |
| EC2 t3.micro (si no se para) | ~$7.50/mes |
| CloudTrail (management events) | Gratis (primer trail) |
| Config Recorder | $0.003/item × recursos = ~$1-3/mes |
| SSM Parameters | Gratis (Standard) |
| CloudWatch Alarms (1) | $0.10/mes |
| S3 (log bucket < 1 GB) | < $0.02/mes |
| **Total mensual si se deja todo** | **~$11-14/mes** |

---

## PASO 1 — Recursos de Fase 6 (EC2, Secrets, KMS app)

```bash
# Variables necesarias (ajustar con tus IDs reales)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
INSTANCE_ID="i-0123456789abcdef0"
SG_ID="sg-0123456789"
KMS_APP_KEY_ARN="arn:aws:kms:eu-west-1:${ACCOUNT_ID}:key/xxxx"
SECRET_ARN="arn:aws:secretsmanager:eu-west-1:${ACCOUNT_ID}:secret:lab/db/credentials-xxxx"

# 1.1 Terminar instancia EC2
aws ec2 terminate-instances --instance-ids $INSTANCE_ID
aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID
echo "EC2 terminada"

# 1.2 Borrar SSM Parameters
aws ssm delete-parameter --name "/lab/config/db-host" --region eu-west-1
aws ssm delete-parameter --name "/lab/config/environment" --region eu-west-1
echo "SSM Parameters borrados"

# 1.3 Borrar secreto en Secrets Manager (ForceDeleteWithoutRecovery para lab)
aws secretsmanager delete-secret \
  --secret-id "lab/db/credentials" \
  --force-delete-without-recovery \
  --region eu-west-1
echo "Secreto eliminado"

# 1.4 Programar eliminación de KMS App Key (min 7 días)
aws kms schedule-key-deletion \
  --key-id $KMS_APP_KEY_ARN \
  --pending-window-in-days 7 \
  --region eu-west-1
aws kms delete-alias --alias-name "alias/lab-app-secrets" --region eu-west-1
echo "KMS app key programada para eliminación en 7 días"

# 1.5 Borrar Security Group (después de terminar la instancia)
sleep 10  # esperar a que la ENI se libere
aws ec2 delete-security-group --group-id $SG_ID 2>/dev/null || echo "SG en uso — reintentar en 1 min"

# 1.6 Borrar IAM Role e Instance Profile
aws iam remove-role-from-instance-profile \
  --instance-profile-name "lab-app-profile" \
  --role-name "lab-app-role"
aws iam delete-instance-profile --instance-profile-name "lab-app-profile"
aws iam delete-role-policy --role-name "lab-app-role" --policy-name "lab-app-minimal-policy"
aws iam detach-role-policy \
  --role-name "lab-app-role" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
aws iam delete-role --role-name "lab-app-role"
echo "IAM Role y Instance Profile eliminados"
```

---

## PASO 2 — Config (Fase 5)

```bash
# 2.1 Borrar Config Rules
for rule in "s3-bucket-public-read-prohibited" "encrypted-volumes" "mfa-enabled-for-iam-console-access"; do
  aws configservice delete-config-rule --config-rule-name "$rule" 2>/dev/null && \
    echo "Rule $rule eliminada"
done

# 2.2 Borrar Config Aggregator
aws configservice delete-configuration-aggregator \
  --configuration-aggregator-name "lab-org-aggregator" 2>/dev/null
echo "Config Aggregator eliminado"

# 2.3 Detener y borrar Config Recorder
aws configservice stop-configuration-recorder \
  --configuration-recorder-name default
aws configservice delete-configuration-recorder \
  --configuration-recorder-name default

# 2.4 Borrar Delivery Channel
aws configservice delete-delivery-channel --delivery-channel-name default

# 2.5 Borrar IAM Role del Config Recorder
aws iam detach-role-policy \
  --role-name "lab-config-recorder-role" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
aws iam delete-role --role-name "lab-config-recorder-role"
echo "Config Recorder, Rules y Delivery Channel eliminados"
```

---

## PASO 3 — CloudTrail y CloudWatch (Fase 4)

```bash
KMS_LOG_KEY_ARN="arn:aws:kms:eu-west-1:${LOGS_ACCOUNT_ID}:key/yyyy"
BUCKET_NAME="org-cloudtrail-logs-${LOGS_ACCOUNT_ID}"
SNS_TOPIC_ARN="arn:aws:sns:eu-west-1:${ACCOUNT_ID}:lab-security-alerts"

# 3.1 Detener y borrar Organization Trail
aws cloudtrail stop-logging --name "lab-org-trail"
aws cloudtrail delete-trail --name "lab-org-trail"
echo "CloudTrail trail eliminado"

# 3.2 Borrar CloudWatch Alarm y Metric Filter
aws cloudwatch delete-alarms --alarm-names "lab-iam-changes"
aws logs delete-metric-filter \
  --log-group-name "/aws/cloudtrail/lab-org-trail" \
  --filter-name "IAMChanges"

# 3.3 Borrar CloudWatch Log Group
aws logs delete-log-group \
  --log-group-name "/aws/cloudtrail/lab-org-trail"

# 3.4 Borrar SNS Topic y suscripciones
aws sns list-subscriptions-by-topic --topic-arn $SNS_TOPIC_ARN \
  --query 'Subscriptions[*].SubscriptionArn' --output text | \
  xargs -I{} aws sns unsubscribe --subscription-arn {}
aws sns delete-topic --topic-arn $SNS_TOPIC_ARN
echo "CloudWatch Logs, Alarms y SNS eliminados"

# 3.5 Borrar IAM Role de CloudTrail → CloudWatch
aws iam delete-role-policy \
  --role-name "lab-cloudtrail-cloudwatch-role" \
  --policy-name "CloudTrailToCloudWatch"
aws iam delete-role --role-name "lab-cloudtrail-cloudwatch-role"
echo "IAM Role de CloudTrail eliminado"
```

---

## PASO 4 — S3 Log Bucket y KMS Log Key (en Log Archive Account)

```bash
# Cambiar a Log Archive Account
LOGS_ACCOUNT_ID="222222222222"
BUCKET_NAME="org-cloudtrail-logs-${LOGS_ACCOUNT_ID}"

aws sts assume-role \
  --role-arn "arn:aws:iam::${LOGS_ACCOUNT_ID}:role/OrganizationAccountAccessRole" \
  --role-session-name "lab-cleanup-logs" > /tmp/logs-cleanup-creds.json

export AWS_ACCESS_KEY_ID=$(jq -r '.Credentials.AccessKeyId' /tmp/logs-cleanup-creds.json)
export AWS_SECRET_ACCESS_KEY=$(jq -r '.Credentials.SecretAccessKey' /tmp/logs-cleanup-creds.json)
export AWS_SESSION_TOKEN=$(jq -r '.Credentials.SessionToken' /tmp/logs-cleanup-creds.json)

# 4.1 Borrar objetos del bucket (con Object Lock Governance: necesitas permiso especial)
# En Governance Mode, puedes borrar con el bypass si eres el bucket owner
aws s3 rm s3://$BUCKET_NAME --recursive \
  --bypass-governance-retention 2>/dev/null || \
  echo "NOTA: Object Lock puede impedir el borrado — usar consola con bypass"

# 4.2 Borrar versiones y delete markers
aws s3api delete-objects \
  --bucket $BUCKET_NAME \
  --delete "$(aws s3api list-object-versions \
    --bucket $BUCKET_NAME \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
    --output json)" 2>/dev/null

# 4.3 Borrar el bucket
aws s3api delete-bucket --bucket $BUCKET_NAME --region eu-west-1
echo "S3 Log bucket eliminado"

# 4.4 Programar eliminación de KMS Log Key
aws kms schedule-key-deletion \
  --key-id $KMS_LOG_KEY_ARN \
  --pending-window-in-days 7 \
  --region eu-west-1
aws kms delete-alias --alias-name "alias/lab-log-archive-key" --region eu-west-1

# Volver a Management Account
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

---

## PASO 5 — Access Analyzer (si se creó)

```bash
aws accessanalyzer delete-analyzer \
  --analyzer-name "lab-access-analyzer" \
  --region eu-west-1 2>/dev/null
echo "Access Analyzer eliminado"
```

---

## PASO 6 — SCPs (Fase 3)

```bash
# 6.1 Desadjuntar SCPs primero (no se pueden borrar si están adjuntas)
for policy_id in $SCP_TRAIL_ID $SCP_REGIONS_ID $SCP_S3_ID; do
  # Desadjuntar de todos los targets
  aws organizations list-targets-for-policy \
    --policy-id "$policy_id" \
    --query 'Targets[*].TargetId' --output text | \
  tr '\t' '\n' | while read target; do
    aws organizations detach-policy \
      --policy-id "$policy_id" \
      --target-id "$target" 2>/dev/null
  done

  # Borrar la SCP
  aws organizations delete-policy --policy-id "$policy_id" 2>/dev/null && \
    echo "SCP $policy_id eliminada"
done
```

---

## PASO 7 — Identity Center (Fase 2)

```bash
# 7.1 Borrar Account Assignments
aws sso-admin list-account-assignments \
  --instance-arn $IDC_INSTANCE_ARN \
  --account-id $DEV_ACCOUNT_ID \
  --permission-set-arn $DEV_PS \
  --query 'AccountAssignments[*]' --output json | \
jq -c '.[]' | while read assignment; do
  principal_type=$(echo $assignment | jq -r '.PrincipalType')
  principal_id=$(echo $assignment | jq -r '.PrincipalId')
  aws sso-admin delete-account-assignment \
    --instance-arn $IDC_INSTANCE_ARN \
    --target-id $DEV_ACCOUNT_ID \
    --target-type AWS_ACCOUNT \
    --permission-set-arn $DEV_PS \
    --principal-type $principal_type \
    --principal-id $principal_id
done

# 7.2 Borrar Permission Sets (primero desadjuntar de todas las cuentas)
for ps_arn in $ADMIN_PS $DEV_PS $RO_PS $OPS_PS; do
  aws sso-admin delete-permission-set \
    --instance-arn $IDC_INSTANCE_ARN \
    --permission-set-arn "$ps_arn" 2>/dev/null && \
    echo "Permission Set eliminado"
done

# 7.3 Borrar usuarios de Identity Center
for user_id in $LAB_ADMIN_USER_ID $LAB_DEV_USER_ID; do
  aws identitystore delete-user \
    --identity-store-id $IDC_IDENTITY_STORE_ID \
    --user-id "$user_id" 2>/dev/null && echo "Usuario eliminado"
done

# 7.4 Deshabilitar Identity Center (desde consola — Settings → Delete)
echo "Deshabilitar Identity Center manualmente desde consola si es necesario"
```

---

## PASO 8 — Organizations: Cuentas y OUs

> ⚠️ **Cerrar una cuenta AWS es un proceso de 90 días.** Las cuentas miembro creadas con `organizations create-account` no se pueden borrar inmediatamente.

```bash
# 8.1 Mover cuentas miembro de vuelta a Root antes de eliminar las OUs
LOGS_ACCOUNT_ID="222222222222"

aws organizations move-account \
  --account-id $LOGS_ACCOUNT_ID \
  --source-parent-id $OU_SECURITY \
  --destination-parent-id $ROOT_ID

# 8.2 Cerrar la cuenta miembro (proceso largo, ~90 días para eliminar)
# OPCIÓN: solo cerrar si el lab ha terminado y no necesitas la cuenta
aws organizations close-account --account-id $LOGS_ACCOUNT_ID
echo "Cuenta Log Archive marcada para cierre (90 días)"

# 8.3 Eliminar OUs (deben estar vacías)
for ou_id in $OU_DEV $OU_WORKLOADS $OU_SHARED $OU_SECURITY; do
  aws organizations delete-organizational-unit \
    --organizational-unit-id "$ou_id" 2>/dev/null && \
    echo "OU $ou_id eliminada"
done

# 8.4 Eliminar la organización (CUIDADO: irreversible, solo si quieres)
# aws organizations delete-organization
# Solo hacer si vas a dejar de usar Organizations completamente
echo "Organización mantenida (recomendado para futuras labs)"
```

---

## PASO 9 — Verificación final

```bash
echo "=== Verificación de cleanup ==="

echo "CloudTrail trails activos:"
aws cloudtrail describe-trails --query 'trailList[*].[Name,IsOrganizationTrail]' --output table

echo "Config Recorders:"
aws configservice describe-configuration-recorder-status 2>/dev/null || echo "Config no activo"

echo "KMS Keys activas (lab):"
aws kms list-aliases --query 'Aliases[?contains(AliasName,`lab`)].AliasName' --output text

echo "EC2 Instances lab (running/stopped):"
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=security-lab01" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' \
  --output table

echo "Secrets Manager (lab):"
aws secretsmanager list-secrets \
  --filter Key=name,Values=lab/ \
  --query 'SecretList[*].[Name,DeletedDate]' --output table

echo "Coste residual estimado: verificar en Cost Explorer en 24-48h"
```

---

## Costes residuales tras cleanup

| Recurso | Estado post-cleanup | Coste |
|---------|--------------------|----|
| KMS CMKs | Scheduled deletion (7 días) | $0 (no factura durante pending deletion) |
| EC2 | Terminated | $0 |
| Secrets Manager | Force deleted | $0 |
| CloudTrail | Deleted | $0 |
| Config | Stopped + Deleted | $0 (factura cierra al día siguiente) |
| S3 | Deleted | $0 |
| Organizations | Mantenido (sin coste) | $0 |
| Identity Center | Mantenido o desactivado | $0 |
| **Total mensual** | | **~$0** |
