#!/usr/bin/env bash
# =============================================================================
# 02-identity-center.sh — IAM Identity Center: Permission Sets y Asignaciones
# Lab: Security & Governance (lab01) — Fase 2
#
# USO: bash ./cli/02-identity-center.sh
# PREREQUISITO: Fase 1 completada, Identity Center habilitado manualmente en consola
# =============================================================================

source "$(dirname "$0")/00-env.sh"

echo "======================================================"
echo " Fase 2 — IAM Identity Center"
echo "======================================================"

# -----------------------------------------------------------------------------
# 2.1 Obtener Instance ARN de Identity Center
# -----------------------------------------------------------------------------
log_info "2.1 Verificando Identity Center..."

IDC_INSTANCE_ARN=$(aws sso-admin list-instances \
  --query 'Instances[0].InstanceArn' \
  --output text 2>/dev/null)

if [[ -z "$IDC_INSTANCE_ARN" || "$IDC_INSTANCE_ARN" == "None" ]]; then
  log_error "Identity Center no está habilitado."
  log_error "Pasos manuales:"
  log_error "  1. Ir a la consola → IAM Identity Center"
  log_error "  2. Click 'Enable' → confirmar → seleccionar región eu-west-1"
  log_error "  3. Volver a ejecutar este script"
  exit 1
fi

IDC_IDENTITY_STORE_ID=$(aws sso-admin list-instances \
  --query 'Instances[0].IdentityStoreId' \
  --output text)

log_ok "Identity Center activo"
log_ok "  Instance ARN    : $IDC_INSTANCE_ARN"
log_ok "  Identity Store  : $IDC_IDENTITY_STORE_ID"
save_state "IDC_INSTANCE_ARN" "$IDC_INSTANCE_ARN"
save_state "IDC_IDENTITY_STORE_ID" "$IDC_IDENTITY_STORE_ID"

# -----------------------------------------------------------------------------
# 2.2 Crear usuarios en el Identity Store
# -----------------------------------------------------------------------------
create_idc_user() {
  local username="$1"
  local display_name="$2"
  local given_name="$3"
  local family_name="$4"
  local email="$5"
  local var_name="$6"

  # Verificar si ya existe
  existing_id=$(aws identitystore list-users \
    --identity-store-id "$IDC_IDENTITY_STORE_ID" \
    --filter "AttributePath=UserName,AttributeValue=${username}" \
    --query 'Users[0].UserId' \
    --output text 2>/dev/null)

  if [[ -n "$existing_id" && "$existing_id" != "None" ]]; then
    log_ok "Usuario '$username' ya existe: $existing_id"
    eval "export ${var_name}='${existing_id}'"
    save_state "$var_name" "$existing_id"
    return 0
  fi

  log_info "Creando usuario '$username'..."
  user_id=$(aws identitystore create-user \
    --identity-store-id "$IDC_IDENTITY_STORE_ID" \
    --user-name "$username" \
    --display-name "$display_name" \
    --name "{\"FamilyName\": \"${family_name}\", \"GivenName\": \"${given_name}\"}" \
    --emails "[{\"Value\": \"${email}\", \"Type\": \"work\", \"Primary\": true}]" \
    --query 'UserId' \
    --output text)

  log_ok "Usuario '$username' creado: $user_id"
  eval "export ${var_name}='${user_id}'"
  save_state "$var_name" "$user_id"
}

log_info "2.2 Creando usuarios..."

ADMIN_EMAIL="${LAB_EMAIL_BASE//@/+labuser@}"
DEV_EMAIL="${LAB_EMAIL_BASE//@/+labdev@}"

create_idc_user "lab-admin" "Lab Admin"     "Lab" "Admin"     "$ADMIN_EMAIL" "LAB_ADMIN_USER_ID"
create_idc_user "lab-dev"   "Lab Developer" "Lab" "Developer" "$DEV_EMAIL"   "LAB_DEV_USER_ID"

echo ""
log_info "Usuarios en Identity Store:"
aws identitystore list-users \
  --identity-store-id "$IDC_IDENTITY_STORE_ID" \
  --query 'Users[*].[UserName,UserId,DisplayName]' \
  --output table

# -----------------------------------------------------------------------------
# 2.3 Crear Permission Sets
# -----------------------------------------------------------------------------
create_permission_set() {
  local name="$1"
  local description="$2"
  local duration="$3"
  local var_name="$4"

  # Verificar si ya existe
  existing_arn=$(aws sso-admin list-permission-sets \
    --instance-arn "$IDC_INSTANCE_ARN" \
    --query 'PermissionSets[]' \
    --output text 2>/dev/null | while read -r arn; do
      ps_name=$(aws sso-admin describe-permission-set \
        --instance-arn "$IDC_INSTANCE_ARN" \
        --permission-set-arn "$arn" \
        --query 'PermissionSet.Name' --output text 2>/dev/null)
      [[ "$ps_name" == "$name" ]] && echo "$arn" && break
    done)

  if [[ -n "$existing_arn" ]]; then
    log_ok "Permission Set '$name' ya existe: $existing_arn"
    eval "export ${var_name}='${existing_arn}'"
    save_state "$var_name" "$existing_arn"
    return 0
  fi

  log_info "Creando Permission Set '$name'..."
  ps_arn=$(aws sso-admin create-permission-set \
    --instance-arn "$IDC_INSTANCE_ARN" \
    --name "$name" \
    --description "$description" \
    --session-duration "$duration" \
    --query 'PermissionSet.PermissionSetArn' \
    --output text)

  log_ok "Permission Set '$name' creado: $ps_arn"
  eval "export ${var_name}='${ps_arn}'"
  save_state "$var_name" "$ps_arn"
}

log_info "2.3 Creando Permission Sets..."

create_permission_set \
  "AdminAccess" \
  "Acceso administrador completo — solo Management Account" \
  "PT4H" \
  "ADMIN_PS"

create_permission_set \
  "DevPowerUser" \
  "PowerUser para entornos de desarrollo — sin IAM full" \
  "PT8H" \
  "DEV_PS"

create_permission_set \
  "ReadOnlyAll" \
  "Lectura en todos los servicios — equipo de seguridad y auditoría" \
  "PT12H" \
  "RO_PS"

create_permission_set \
  "OpsSession" \
  "Acceso operativo mínimo: SSM Session Manager + CloudWatch + Secrets Manager" \
  "PT4H" \
  "OPS_PS"

# -----------------------------------------------------------------------------
# Adjuntar políticas managed a los Permission Sets
# -----------------------------------------------------------------------------
attach_managed_policy() {
  local ps_arn="$1"
  local policy_arn="$2"
  local policy_name="$3"

  aws sso-admin attach-managed-policy-to-permission-set \
    --instance-arn "$IDC_INSTANCE_ARN" \
    --permission-set-arn "$ps_arn" \
    --managed-policy-arn "$policy_arn" 2>/dev/null && \
    log_ok "  Adjuntada: $policy_name" || \
    log_warn "  $policy_name — ya adjuntada o error"
}

log_info "Adjuntando políticas a AdminAccess..."
attach_managed_policy "$ADMIN_PS" \
  "arn:aws:iam::aws:policy/AdministratorAccess" \
  "AdministratorAccess"

log_info "Adjuntando políticas a DevPowerUser..."
attach_managed_policy "$DEV_PS" \
  "arn:aws:iam::aws:policy/PowerUserAccess" \
  "PowerUserAccess"
attach_managed_policy "$DEV_PS" \
  "arn:aws:iam::aws:policy/AmazonSSMFullAccess" \
  "AmazonSSMFullAccess"

log_info "Adjuntando políticas a ReadOnlyAll..."
attach_managed_policy "$RO_PS" \
  "arn:aws:iam::aws:policy/ReadOnlyAccess" \
  "ReadOnlyAccess"
attach_managed_policy "$RO_PS" \
  "arn:aws:iam::aws:policy/SecurityAudit" \
  "SecurityAudit"

# -----------------------------------------------------------------------------
# Policy inline para OpsSession (mínimo privilegio)
# -----------------------------------------------------------------------------
log_info "Configurando policy inline para OpsSession..."

OPS_INLINE_POLICY=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SSMSessionManager",
      "Effect": "Allow",
      "Action": [
        "ssm:StartSession",
        "ssm:TerminateSession",
        "ssm:ResumeSession",
        "ssm:DescribeSessions",
        "ssm:GetConnectionStatus",
        "ssm:DescribeInstanceProperties",
        "ec2:DescribeInstances"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "logs:GetLogEvents",
        "cloudwatch:GetMetricData",
        "cloudwatch:DescribeAlarms"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SecretsManagerRead",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:ListSecrets"
      ],
      "Resource": "arn:aws:secretsmanager:eu-west-1:*:secret:lab/*"
    }
  ]
}
EOF
)

aws sso-admin put-inline-policy-to-permission-set \
  --instance-arn "$IDC_INSTANCE_ARN" \
  --permission-set-arn "$OPS_PS" \
  --inline-policy "$OPS_INLINE_POLICY" 2>/dev/null && \
  log_ok "Policy inline OpsSession configurada" || \
  log_warn "Policy inline OpsSession — ya existe o error"

# -----------------------------------------------------------------------------
# 2.4 Crear Account Assignments
# -----------------------------------------------------------------------------
create_assignment() {
  local account_id="$1"
  local ps_arn="$2"
  local user_id="$3"
  local description="$4"

  log_info "Asignación: $description"
  result=$(aws sso-admin create-account-assignment \
    --instance-arn "$IDC_INSTANCE_ARN" \
    --target-id "$account_id" \
    --target-type AWS_ACCOUNT \
    --permission-set-arn "$ps_arn" \
    --principal-type USER \
    --principal-id "$user_id" \
    --query 'AccountAssignmentCreationStatus.Status' \
    --output text 2>/dev/null || echo "FAILED")

  if [[ "$result" == "FAILED" ]]; then
    log_warn "  Asignación fallida o ya existe para: $description"
  else
    log_ok "  $description → $result"
  fi
}

log_info "2.4 Creando Account Assignments..."

# lab-admin → AdminAccess → Management Account
create_assignment \
  "$MGMT_ACCOUNT_ID" \
  "$ADMIN_PS" \
  "$LAB_ADMIN_USER_ID" \
  "lab-admin → AdminAccess → Management Account"

# lab-dev → DevPowerUser → Dev Account (si existe)
if [[ "$DEV_ACCOUNT_ID" != "333333333333" ]]; then
  create_assignment \
    "$DEV_ACCOUNT_ID" \
    "$DEV_PS" \
    "$LAB_DEV_USER_ID" \
    "lab-dev → DevPowerUser → Dev Account"
else
  log_warn "Dev Account no configurado, saltando asignación (actualizar DEV_ACCOUNT_ID)"
fi

# lab-dev → ReadOnlyAll → Management Account (para auditoría)
create_assignment \
  "$MGMT_ACCOUNT_ID" \
  "$RO_PS" \
  "$LAB_DEV_USER_ID" \
  "lab-dev → ReadOnlyAll → Management Account"

# lab-admin → OpsSession → Management Account
create_assignment \
  "$MGMT_ACCOUNT_ID" \
  "$OPS_PS" \
  "$LAB_ADMIN_USER_ID" \
  "lab-admin → OpsSession → Management Account"

# -----------------------------------------------------------------------------
# Verificación final
# -----------------------------------------------------------------------------
echo ""
echo "======================================================"
echo " Fase 2 — COMPLETADA"
echo "======================================================"

echo ""
log_info "Permission Sets creados:"
echo "  ADMIN_PS : $ADMIN_PS"
echo "  DEV_PS   : $DEV_PS"
echo "  RO_PS    : $RO_PS"
echo "  OPS_PS   : $OPS_PS"

echo ""
log_info "Usuarios creados:"
echo "  LAB_ADMIN_USER_ID : $LAB_ADMIN_USER_ID"
echo "  LAB_DEV_USER_ID   : $LAB_DEV_USER_ID"

echo ""
log_info "Para verificar el login SSO:"
SSO_URL=$(aws sso-admin list-instances \
  --query 'Instances[0].PortalUrl' \
  --output text 2>/dev/null || echo "N/A")
echo "  SSO Portal URL: ${SSO_URL}"
echo "  1. Abre ventana incógnito → $SSO_URL"
echo "  2. Login con lab-admin (establecer contraseña desde el email de invitación)"
echo "  3. Verificar cuentas y roles disponibles"
echo ""
log_info "Para verificar por CLI:"
echo "  aws configure sso --profile lab-admin-sso"
echo "  aws sts get-caller-identity --profile lab-admin-sso"
echo ""
log_ok "Estado guardado en: $STATE_FILE"
log_info "Siguiente paso: bash ./cli/03-scps.sh"
