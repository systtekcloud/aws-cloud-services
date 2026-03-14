#!/usr/bin/env bash
# =============================================================================
# 99-cleanup.sh — Cleanup completo ordenado para lab01-security-governance
# Lab: Security & Governance (lab01)
#
# USO: bash ./cli/99-cleanup.sh
# IMPORTANTE: Seguir el orden estricto para evitar errores de dependencias
# =============================================================================

source "$(dirname "$0")/00-env.sh"

echo "======================================================"
echo " Cleanup — Lab01 Security & Governance"
echo "======================================================"
echo ""
echo "Recursos a eliminar (estimación de coste si se dejan activos: ~\$11-14/mes):"
echo "  - EC2 t3.micro            ~\$7.50/mes"
echo "  - KMS CMK x2              ~\$2.00/mes"
echo "  - Secrets Manager         ~\$0.40/mes"
echo "  - Config Recorder         ~\$1-3/mes"
echo "  - CloudWatch Alarm x1     ~\$0.10/mes"
echo ""

confirm_action "¿Estás seguro de que quieres eliminar TODOS los recursos del lab?"

# -----------------------------------------------------------------------------
# PASO 1 — Recursos de Fase 6 (EC2, Secrets, KMS app, IAM, SSM)
# -----------------------------------------------------------------------------
echo ""
log_info "PASO 1 — Fase 6: EC2 + Secrets Manager + KMS app + IAM + SSM"

# 1.1 Terminar instancia EC2
if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "i-0123456789abcdef0" ]]; then
  log_info "  Terminando instancia EC2: $INSTANCE_ID"
  aws ec2 terminate-instances \
    --instance-ids "$INSTANCE_ID" \
    --region eu-west-1 2>/dev/null || log_warn "  EC2 ya terminada o no encontrada"

  log_info "  Esperando que la instancia termine..."
  aws ec2 wait instance-terminated \
    --instance-ids "$INSTANCE_ID" \
    --region eu-west-1 2>/dev/null && \
    log_ok "  EC2 terminada: $INSTANCE_ID" || \
    log_warn "  Timeout esperando terminación de EC2"
else
  log_warn "  INSTANCE_ID no configurado — buscar instancias con tag Project=$LAB_TAG_VALUE"
  FOUND_INSTANCE=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=${LAB_TAG_VALUE}" \
              "Name=instance-state-name,Values=running,stopped" \
    --region eu-west-1 \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text 2>/dev/null)
  if [[ -n "$FOUND_INSTANCE" ]]; then
    log_info "  Instancias encontradas: $FOUND_INSTANCE"
    aws ec2 terminate-instances --instance-ids $FOUND_INSTANCE --region eu-west-1
    aws ec2 wait instance-terminated --instance-ids $FOUND_INSTANCE --region eu-west-1 2>/dev/null
    log_ok "  EC2 terminada"
  fi
fi

# 1.2 Borrar SSM Parameters
log_info "  Borrando SSM Parameters..."
for param in "/lab/config/db-host" "/lab/config/environment"; do
  aws ssm delete-parameter --name "$param" --region eu-west-1 2>/dev/null && \
    log_ok "  SSM eliminado: $param" || \
    log_warn "  SSM no encontrado: $param"
done

# 1.3 Borrar secreto en Secrets Manager
log_info "  Borrando secreto en Secrets Manager..."
aws secretsmanager delete-secret \
  --secret-id "lab/db/credentials" \
  --force-delete-without-recovery \
  --region eu-west-1 2>/dev/null && \
  log_ok "  Secreto eliminado: lab/db/credentials" || \
  log_warn "  Secreto no encontrado o ya eliminado"

# 1.4 Programar eliminación de KMS App Key (mín 7 días)
if [[ -n "$KMS_APP_KEY_ARN" ]]; then
  log_info "  Programando eliminación de KMS App Key..."
  aws kms schedule-key-deletion \
    --key-id "$KMS_APP_KEY_ARN" \
    --pending-window-in-days 7 \
    --region eu-west-1 2>/dev/null && \
    log_ok "  KMS App Key programada para eliminación en 7 días" || \
    log_warn "  KMS App Key: ya en pending deletion o no encontrada"

  aws kms delete-alias \
    --alias-name "alias/lab-app-secrets" \
    --region eu-west-1 2>/dev/null && \
    log_ok "  KMS alias eliminado" || \
    log_warn "  KMS alias ya no existe"
fi

# 1.5 Borrar Security Group
log_info "  Borrando Security Group..."
sleep 15  # Esperar a que la ENI se libere tras terminar EC2
if [[ -n "$SG_ID" ]]; then
  aws ec2 delete-security-group \
    --group-id "$SG_ID" \
    --region eu-west-1 2>/dev/null && \
    log_ok "  SG eliminado: $SG_ID" || \
    log_warn "  SG aún en uso — reintentar en 1 min: aws ec2 delete-security-group --group-id $SG_ID --region eu-west-1"
fi

# 1.6 Borrar IAM Role e Instance Profile
log_info "  Borrando IAM Role e Instance Profile..."

aws iam remove-role-from-instance-profile \
  --instance-profile-name "lab-app-profile" \
  --role-name "lab-app-role" 2>/dev/null || true

aws iam delete-instance-profile \
  --instance-profile-name "lab-app-profile" 2>/dev/null && \
  log_ok "  Instance Profile eliminado" || \
  log_warn "  Instance Profile no encontrado"

aws iam delete-role-policy \
  --role-name "lab-app-role" \
  --policy-name "lab-app-minimal-policy" 2>/dev/null || true

aws iam detach-role-policy \
  --role-name "lab-app-role" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" 2>/dev/null || true

aws iam delete-role \
  --role-name "lab-app-role" 2>/dev/null && \
  log_ok "  IAM Role eliminado: lab-app-role" || \
  log_warn "  IAM Role no encontrado: lab-app-role"

# -----------------------------------------------------------------------------
# PASO 2 — Config (Fase 5)
# -----------------------------------------------------------------------------
echo ""
log_info "PASO 2 — AWS Config: Rules + Aggregator + Recorder + Delivery Channel"

# 2.1 Borrar Config Rules
for rule in \
  "s3-bucket-public-read-prohibited" \
  "encrypted-volumes" \
  "mfa-enabled-for-iam-console-access" \
  "root-account-mfa-enabled" \
  "cloudtrail-enabled"; do

  aws configservice delete-config-rule \
    --config-rule-name "$rule" \
    --region eu-west-1 2>/dev/null && \
    log_ok "  Rule eliminada: $rule" || \
    log_warn "  Rule no encontrada: $rule"
done

# 2.2 Borrar Config Aggregator
aws configservice delete-configuration-aggregator \
  --configuration-aggregator-name "lab-org-aggregator" \
  --region eu-west-1 2>/dev/null && \
  log_ok "  Config Aggregator eliminado" || \
  log_warn "  Config Aggregator no encontrado"

# 2.3 Detener y borrar Config Recorder
aws configservice stop-configuration-recorder \
  --configuration-recorder-name "lab-config-recorder" \
  --region eu-west-1 2>/dev/null || true

aws configservice delete-configuration-recorder \
  --configuration-recorder-name "lab-config-recorder" \
  --region eu-west-1 2>/dev/null && \
  log_ok "  Config Recorder eliminado" || \
  log_warn "  Config Recorder no encontrado"

# 2.4 Borrar Delivery Channel
aws configservice delete-delivery-channel \
  --delivery-channel-name "lab-config-delivery" \
  --region eu-west-1 2>/dev/null && \
  log_ok "  Config Delivery Channel eliminado" || \
  log_warn "  Config Delivery Channel no encontrado"

# 2.5 Borrar IAM Role de Config
aws iam detach-role-policy \
  --role-name "lab-config-recorder-role" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole" 2>/dev/null || true

aws iam delete-role-policy \
  --role-name "lab-config-recorder-role" \
  --policy-name "ConfigS3CrossAccount" 2>/dev/null || true

aws iam delete-role \
  --role-name "lab-config-recorder-role" 2>/dev/null && \
  log_ok "  IAM Role Config eliminado" || \
  log_warn "  IAM Role Config no encontrado"

# -----------------------------------------------------------------------------
# PASO 3 — CloudTrail + CloudWatch (Fase 4)
# -----------------------------------------------------------------------------
echo ""
log_info "PASO 3 — CloudTrail + CloudWatch Logs + SNS"

# 3.1 Detener y borrar Organization Trail
aws cloudtrail stop-logging \
  --name "lab-org-trail" \
  --region eu-west-1 2>/dev/null || true

aws cloudtrail delete-trail \
  --name "lab-org-trail" \
  --region eu-west-1 2>/dev/null && \
  log_ok "  CloudTrail trail eliminado" || \
  log_warn "  CloudTrail trail no encontrado"

# 3.2 Borrar CloudWatch Alarm
aws cloudwatch delete-alarms \
  --alarm-names "lab-iam-changes" \
  --region eu-west-1 2>/dev/null && \
  log_ok "  CloudWatch Alarm eliminada" || \
  log_warn "  CloudWatch Alarm no encontrada"

# 3.3 Borrar Metric Filter
aws logs delete-metric-filter \
  --log-group-name "/aws/cloudtrail/lab-org-trail" \
  --filter-name "IAMChanges" \
  --region eu-west-1 2>/dev/null && \
  log_ok "  Metric Filter eliminado" || \
  log_warn "  Metric Filter no encontrado"

# 3.4 Borrar CloudWatch Log Group
aws logs delete-log-group \
  --log-group-name "/aws/cloudtrail/lab-org-trail" \
  --region eu-west-1 2>/dev/null && \
  log_ok "  CloudWatch Log Group eliminado" || \
  log_warn "  CloudWatch Log Group no encontrado"

# 3.5 Borrar SNS Topic y suscripciones
if [[ -n "$SNS_TOPIC_ARN" ]]; then
  log_info "  Borrando suscripciones SNS..."
  subs=$(aws sns list-subscriptions-by-topic \
    --topic-arn "$SNS_TOPIC_ARN" \
    --region eu-west-1 \
    --query 'Subscriptions[*].SubscriptionArn' \
    --output text 2>/dev/null)

  for sub in $subs; do
    [[ "$sub" == "PendingConfirmation" ]] && continue
    aws sns unsubscribe --subscription-arn "$sub" --region eu-west-1 2>/dev/null || true
  done

  aws sns delete-topic \
    --topic-arn "$SNS_TOPIC_ARN" \
    --region eu-west-1 2>/dev/null && \
    log_ok "  SNS Topic eliminado" || \
    log_warn "  SNS Topic no encontrado"
fi

# 3.6 Borrar IAM Role de CloudTrail → CloudWatch
aws iam delete-role-policy \
  --role-name "lab-cloudtrail-cloudwatch-role" \
  --policy-name "CloudTrailToCloudWatch" 2>/dev/null || true

aws iam delete-role \
  --role-name "lab-cloudtrail-cloudwatch-role" 2>/dev/null && \
  log_ok "  IAM Role CloudTrail eliminado" || \
  log_warn "  IAM Role CloudTrail no encontrado"

# -----------------------------------------------------------------------------
# PASO 4 — S3 Log Bucket + KMS Log Key (en Log Archive Account)
# -----------------------------------------------------------------------------
echo ""
log_info "PASO 4 — S3 Log Bucket + KMS Log Key (Log Archive Account)"

if [[ "$LOGS_ACCOUNT_ID" != "222222222222" ]]; then
  assume_role "$LOGS_ACCOUNT_ID" "lab-cleanup-logs"

  BUCKET_NAME_CLEANUP="org-cloudtrail-logs-${LOGS_ACCOUNT_ID}"

  # 4.1 Borrar objetos del bucket (con bypass de Object Lock Governance)
  log_info "  Vaciando bucket: $BUCKET_NAME_CLEANUP"
  aws s3 rm "s3://${BUCKET_NAME_CLEANUP}" \
    --recursive \
    --region eu-west-1 2>/dev/null || \
    log_warn "  No se pudo vaciar con s3 rm — intentando con delete-objects"

  # 4.2 Borrar versiones y delete markers (Object Lock)
  log_info "  Borrando versiones y delete markers..."
  versions=$(aws s3api list-object-versions \
    --bucket "$BUCKET_NAME_CLEANUP" \
    --region eu-west-1 \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
    --output json 2>/dev/null)

  if [[ -n "$versions" && "$versions" != '{"Objects": null}' ]]; then
    aws s3api delete-objects \
      --bucket "$BUCKET_NAME_CLEANUP" \
      --delete "$versions" \
      --bypass-governance-retention \
      --region eu-west-1 2>/dev/null && \
      log_ok "  Versiones eliminadas" || \
      log_warn "  No se pudieron eliminar versiones — usar consola con bypass"
  fi

  # Delete markers
  markers=$(aws s3api list-object-versions \
    --bucket "$BUCKET_NAME_CLEANUP" \
    --region eu-west-1 \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
    --output json 2>/dev/null)

  if [[ -n "$markers" && "$markers" != '{"Objects": null}' ]]; then
    aws s3api delete-objects \
      --bucket "$BUCKET_NAME_CLEANUP" \
      --delete "$markers" \
      --region eu-west-1 2>/dev/null || true
  fi

  # 4.3 Borrar el bucket
  aws s3api delete-bucket \
    --bucket "$BUCKET_NAME_CLEANUP" \
    --region eu-west-1 2>/dev/null && \
    log_ok "  S3 Log Bucket eliminado: $BUCKET_NAME_CLEANUP" || \
    log_warn "  S3 Bucket no eliminado — puede quedar contenido con Object Lock activo"

  # 4.4 Programar eliminación de KMS Log Key
  if [[ -n "$KMS_LOG_KEY_ARN" ]]; then
    aws kms schedule-key-deletion \
      --key-id "$KMS_LOG_KEY_ARN" \
      --pending-window-in-days 7 \
      --region eu-west-1 2>/dev/null && \
      log_ok "  KMS Log Key programada para eliminación en 7 días" || \
      log_warn "  KMS Log Key: ya en pending deletion"

    aws kms delete-alias \
      --alias-name "alias/lab-log-archive-key" \
      --region eu-west-1 2>/dev/null || true
  fi

  restore_mgmt_account
else
  log_warn "  LOGS_ACCOUNT_ID no configurado — limpiar S3 y KMS manualmente en Log Archive Account"
fi

# -----------------------------------------------------------------------------
# PASO 5 — Access Analyzer (si se creó)
# -----------------------------------------------------------------------------
echo ""
log_info "PASO 5 — Access Analyzer"

aws accessanalyzer delete-analyzer \
  --analyzer-name "lab-access-analyzer" \
  --region eu-west-1 2>/dev/null && \
  log_ok "  Access Analyzer eliminado" || \
  log_warn "  Access Analyzer no encontrado (puede no haberse creado)"

# -----------------------------------------------------------------------------
# PASO 6 — SCPs (desadjuntar primero, luego borrar)
# -----------------------------------------------------------------------------
echo ""
log_info "PASO 6 — SCPs (desadjuntar antes de borrar)"

cleanup_scp() {
  local policy_id="$1"
  local name="$2"

  [[ -z "$policy_id" ]] && log_warn "  SCP $name: ID no configurado — buscar manualmente" && return

  log_info "  Desadjuntando SCP $name ($policy_id)..."
  targets=$(aws organizations list-targets-for-policy \
    --policy-id "$policy_id" \
    --query 'Targets[*].TargetId' \
    --output text 2>/dev/null || echo "")

  for target in $targets; do
    aws organizations detach-policy \
      --policy-id "$policy_id" \
      --target-id "$target" 2>/dev/null && \
      log_ok "  Desadjuntada de: $target" || \
      log_warn "  No se pudo desadjuntar de: $target"
  done

  aws organizations delete-policy \
    --policy-id "$policy_id" 2>/dev/null && \
    log_ok "  SCP eliminada: $name" || \
    log_warn "  SCP no eliminada: $name"
}

cleanup_scp "$SCP_TRAIL_ID"   "SCP-001-DenyDisableCloudTrail"
cleanup_scp "$SCP_REGIONS_ID" "SCP-002-DenyRegionsExceptApproved"
cleanup_scp "$SCP_S3_ID"      "SCP-003-DenyS3PublicAccess"

# SCP-004 si existe
SCP_LEAVE_ID=$(aws organizations list-policies \
  --filter SERVICE_CONTROL_POLICY \
  --query "Policies[?Name=='SCP-004-DenyLeaveOrganization'].Id" \
  --output text 2>/dev/null)
[[ -n "$SCP_LEAVE_ID" ]] && cleanup_scp "$SCP_LEAVE_ID" "SCP-004-DenyLeaveOrganization"

# -----------------------------------------------------------------------------
# PASO 7 — Identity Center (Fase 2)
# -----------------------------------------------------------------------------
echo ""
log_info "PASO 7 — IAM Identity Center"

if [[ -n "$IDC_INSTANCE_ARN" ]]; then
  # 7.1 Borrar Account Assignments (iterar por cada permission set)
  log_info "  Borrando Account Assignments..."
  for ps_arn in $ADMIN_PS $DEV_PS $RO_PS $OPS_PS; do
    [[ -z "$ps_arn" ]] && continue
    for acct in $MGMT_ACCOUNT_ID $DEV_ACCOUNT_ID; do
      [[ -z "$acct" ]] && continue
      assignments=$(aws sso-admin list-account-assignments \
        --instance-arn "$IDC_INSTANCE_ARN" \
        --account-id "$acct" \
        --permission-set-arn "$ps_arn" \
        --query 'AccountAssignments[*]' \
        --output json 2>/dev/null || echo "[]")

      echo "$assignments" | python3 -c "
import sys, json, subprocess
assignments = json.load(sys.stdin)
for a in assignments:
    cmd = [
        'aws', 'sso-admin', 'delete-account-assignment',
        '--instance-arn', '${IDC_INSTANCE_ARN}',
        '--target-id', a['AccountId'],
        '--target-type', 'AWS_ACCOUNT',
        '--permission-set-arn', a['PermissionSetArn'],
        '--principal-type', a['PrincipalType'],
        '--principal-id', a['PrincipalId']
    ]
    subprocess.run(cmd, capture_output=True)
    print(f'  Asignación eliminada: {a[\"PrincipalType\"]} → {a[\"AccountId\"]}')
" 2>/dev/null || true
    done
  done

  # 7.2 Borrar Permission Sets
  log_info "  Borrando Permission Sets..."
  for ps_arn in $ADMIN_PS $DEV_PS $RO_PS $OPS_PS; do
    [[ -z "$ps_arn" ]] && continue
    aws sso-admin delete-permission-set \
      --instance-arn "$IDC_INSTANCE_ARN" \
      --permission-set-arn "$ps_arn" 2>/dev/null && \
      log_ok "  Permission Set eliminado: $ps_arn" || \
      log_warn "  Permission Set no eliminado: $ps_arn"
  done

  # 7.3 Borrar usuarios
  log_info "  Borrando usuarios de Identity Center..."
  for user_id in $LAB_ADMIN_USER_ID $LAB_DEV_USER_ID; do
    [[ -z "$user_id" ]] && continue
    aws identitystore delete-user \
      --identity-store-id "$IDC_IDENTITY_STORE_ID" \
      --user-id "$user_id" 2>/dev/null && \
      log_ok "  Usuario eliminado: $user_id" || \
      log_warn "  Usuario no encontrado: $user_id"
  done

  log_warn "  Para deshabilitar Identity Center completamente: consola → IAM Identity Center → Settings → Delete"
else
  log_warn "  IDC_INSTANCE_ARN no configurado — limpiar Identity Center manualmente"
fi

# -----------------------------------------------------------------------------
# PASO 8 — Organizations: Cuentas y OUs (opcional)
# -----------------------------------------------------------------------------
echo ""
log_info "PASO 8 — Organizations (opcional — ver notas)"
echo ""
log_warn "  NOTA: Cerrar una cuenta AWS tarda 90 días y es irreversible."
log_warn "  Se recomienda mantener la estructura de Organizations para futuros labs."
echo ""
echo "  Pasos opcionales (NO ejecutados automáticamente):"
echo "  # 8.1 Mover cuentas de vuelta a Root"
echo "  aws organizations move-account --account-id $LOGS_ACCOUNT_ID \\"
echo "    --source-parent-id $OU_SECURITY --destination-parent-id $ROOT_ID"
echo ""
echo "  # 8.2 Cerrar cuenta miembro (proceso de 90 días)"
echo "  aws organizations close-account --account-id $LOGS_ACCOUNT_ID"
echo ""
echo "  # 8.3 Eliminar OUs vacías"
echo "  for ou in $OU_DEV $OU_WORKLOADS $OU_SHARED $OU_SECURITY; do"
echo "    aws organizations delete-organizational-unit --organizational-unit-id \"\$ou\""
echo "  done"
echo ""
echo "  # 8.4 Eliminar organización (CUIDADO — irreversible)"
echo "  # aws organizations delete-organization"

# -----------------------------------------------------------------------------
# PASO 9 — Verificación final
# -----------------------------------------------------------------------------
echo ""
log_info "PASO 9 — Verificación final"
echo ""
echo "=== Estado post-cleanup ==="

echo ""
echo "CloudTrail trails activos:"
aws cloudtrail describe-trails \
  --include-shadow-trails false \
  --query 'trailList[*].[Name,IsOrganizationTrail]' \
  --output table 2>/dev/null || echo "  Ninguno"

echo ""
echo "Config Recorders:"
aws configservice describe-configuration-recorder-status \
  --region eu-west-1 2>/dev/null || echo "  Config no activo"

echo ""
echo "KMS Keys activas (lab aliases):"
aws kms list-aliases \
  --region eu-west-1 \
  --query 'Aliases[?contains(AliasName,`lab`)].AliasName' \
  --output text 2>/dev/null || echo "  Ninguna"

echo ""
echo "EC2 Instances lab (running/stopped):"
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=${LAB_TAG_VALUE}" \
  --region eu-west-1 \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' \
  --output table 2>/dev/null || echo "  Ninguna"

echo ""
echo "Secrets Manager (lab/):"
aws secretsmanager list-secrets \
  --filter "Key=name,Values=lab/" \
  --region eu-west-1 \
  --query 'SecretList[*].[Name,DeletedDate]' \
  --output table 2>/dev/null || echo "  Ninguno"

# Limpiar archivo de estado del lab
echo ""
log_info "Limpiando archivo de estado..."
if [[ -f "$STATE_FILE" ]]; then
  mv "$STATE_FILE" "${STATE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  log_ok "Estado guardado como backup y limpiado"
fi

# -----------------------------------------------------------------------------
# Resumen de costes post-cleanup
# -----------------------------------------------------------------------------
echo ""
echo "======================================================"
echo " Cleanup COMPLETADO"
echo "======================================================"
echo ""
echo "Coste residual estimado post-cleanup:"
echo "  KMS CMKs          → Pending deletion (no factura durante pending)"
echo "  EC2               → Terminated (\$0)"
echo "  Secrets Manager   → Force deleted (\$0)"
echo "  CloudTrail        → Deleted (\$0)"
echo "  Config            → Stopped + Deleted (\$0, factura cierra al día siguiente)"
echo "  S3 Log Bucket     → Deleted (\$0)"
echo "  Organizations     → Mantenido (sin coste) (\$0)"
echo "  Identity Center   → Mantenido o desactivado (\$0)"
echo ""
echo "  Total estimado    → ~\$0/mes"
echo ""
log_warn "Verificar coste real en AWS Cost Explorer en 24-48h"
log_info "Para dudas sobre recursos no eliminados: revisar AWS Console → Tag Editor → Project=security-lab01"
