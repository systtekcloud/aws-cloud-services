#!/usr/bin/env bash
# =============================================================================
# 01-organizations.sh — Crear AWS Organizations, OUs y cuenta miembro
# Lab: Security & Governance (lab01) — Fase 1
#
# USO: bash ./cli/01-organizations.sh
# PREREQUISITO: Cuenta AWS con facturación activada, credenciales en ~/.aws/
# =============================================================================

source "$(dirname "$0")/00-env.sh"

echo "======================================================"
echo " Fase 1 — AWS Organizations + OUs + Cuentas"
echo "======================================================"

# -----------------------------------------------------------------------------
# 1.1 Habilitar Organizations
# -----------------------------------------------------------------------------
log_info "1.1 Verificando/creando AWS Organizations..."

if aws organizations describe-organization &>/dev/null; then
  ORG_ID=$(aws organizations describe-organization \
    --query 'Organization.Id' --output text)
  log_ok "Organizations ya existe: $ORG_ID"
else
  log_info "Creando organización con feature-set ALL..."
  aws organizations create-organization --feature-set ALL
  log_ok "Organizations creado"
fi

# Obtener Root ID
ROOT_ID=$(aws organizations list-roots \
  --query 'Roots[0].Id' --output text)
log_ok "Root ID: $ROOT_ID"
save_state "ROOT_ID" "$ROOT_ID"

# -----------------------------------------------------------------------------
# 1.2 Crear OUs de primer nivel
# -----------------------------------------------------------------------------
log_info "1.2 Creando OUs de primer nivel..."

create_ou_if_missing() {
  local parent_id="$1"
  local name="$2"
  local var_name="$3"

  # Verificar si ya existe
  existing=$(aws organizations list-organizational-units-for-parent \
    --parent-id "$parent_id" \
    --query "OrganizationalUnits[?Name=='${name}'].Id" \
    --output text 2>/dev/null)

  if [[ -n "$existing" && "$existing" != "None" ]]; then
    log_ok "OU '$name' ya existe: $existing"
    eval "export ${var_name}='${existing}'"
    save_state "$var_name" "$existing"
  else
    ou_id=$(aws organizations create-organizational-unit \
      --parent-id "$parent_id" \
      --name "$name" \
      --query 'OrganizationalUnit.Id' \
      --output text)
    log_ok "OU '$name' creada: $ou_id"
    eval "export ${var_name}='${ou_id}'"
    save_state "$var_name" "$ou_id"
  fi
}

create_ou_if_missing "$ROOT_ID"    "Security"       "OU_SECURITY"
create_ou_if_missing "$ROOT_ID"    "SharedServices" "OU_SHARED"
create_ou_if_missing "$ROOT_ID"    "Workloads"      "OU_WORKLOADS"
create_ou_if_missing "$OU_WORKLOADS" "Dev"          "OU_DEV"

# Listar OUs
echo ""
log_info "OUs creadas:"
aws organizations list-organizational-units-for-parent \
  --parent-id "$ROOT_ID" \
  --query 'OrganizationalUnits[*].[Name,Id]' \
  --output table

# -----------------------------------------------------------------------------
# 1.3 Crear cuenta miembro Log Archive
# -----------------------------------------------------------------------------
log_info "1.3 Creando cuenta miembro Log Archive..."

LOGS_EMAIL="${LAB_EMAIL_BASE//@/+logs@}"
# Alternativa con gmail alias si el email no soporta +
# LOGS_EMAIL="$(echo $LAB_EMAIL_BASE | sed 's/@/+logs@/')"

# Verificar si la cuenta ya existe en la org
existing_logs=$(aws organizations list-accounts \
  --query "Accounts[?Name=='lab-log-archive'].Id" \
  --output text 2>/dev/null)

if [[ -n "$existing_logs" && "$existing_logs" != "None" ]]; then
  LOGS_ACCOUNT_ID="$existing_logs"
  log_ok "Cuenta 'lab-log-archive' ya existe: $LOGS_ACCOUNT_ID"
  save_state "LOGS_ACCOUNT_ID" "$LOGS_ACCOUNT_ID"
else
  log_info "Creando cuenta 'lab-log-archive' con email: $LOGS_EMAIL"
  log_warn "Este proceso tarda 2-3 minutos..."

  CREATE_STATUS=$(aws organizations create-account \
    --email "$LOGS_EMAIL" \
    --account-name "lab-log-archive" \
    --role-name "OrganizationAccountAccessRole" \
    --query 'CreateAccountStatus.Id' \
    --output text)

  log_info "Request ID: $CREATE_STATUS — polling estado..."

  # Polling hasta que la cuenta esté activa
  for i in $(seq 1 30); do
    STATUS=$(aws organizations describe-create-account-status \
      --create-account-request-id "$CREATE_STATUS" \
      --query 'CreateAccountStatus.State' \
      --output text)
    echo "  Intento $i/30 — estado: $STATUS"
    if [[ "$STATUS" == "SUCCEEDED" ]]; then break; fi
    if [[ "$STATUS" == "FAILED" ]]; then
      FAIL_REASON=$(aws organizations describe-create-account-status \
        --create-account-request-id "$CREATE_STATUS" \
        --query 'CreateAccountStatus.FailureReason' --output text)
      log_error "Creación de cuenta fallida: $FAIL_REASON"
      exit 1
    fi
    sleep 15
  done

  LOGS_ACCOUNT_ID=$(aws organizations describe-create-account-status \
    --create-account-request-id "$CREATE_STATUS" \
    --query 'CreateAccountStatus.AccountId' \
    --output text)
  log_ok "Cuenta creada: $LOGS_ACCOUNT_ID"
  save_state "LOGS_ACCOUNT_ID" "$LOGS_ACCOUNT_ID"
fi

# Mover cuenta a OU Security
current_parent=$(aws organizations list-parents \
  --child-id "$LOGS_ACCOUNT_ID" \
  --query 'Parents[0].Id' --output text 2>/dev/null || echo "")

if [[ "$current_parent" != "$OU_SECURITY" ]]; then
  log_info "Moviendo cuenta a OU Security..."
  aws organizations move-account \
    --account-id "$LOGS_ACCOUNT_ID" \
    --source-parent-id "${current_parent:-$ROOT_ID}" \
    --destination-parent-id "$OU_SECURITY"
  log_ok "Cuenta movida a OU Security"
else
  log_ok "Cuenta ya está en OU Security"
fi

# Actualizar BUCKET_NAME con el ID real
export BUCKET_NAME="org-cloudtrail-logs-${LOGS_ACCOUNT_ID}"
save_state "BUCKET_NAME" "$BUCKET_NAME"

# -----------------------------------------------------------------------------
# 1.4 Verificar AssumeRole a la cuenta miembro
# -----------------------------------------------------------------------------
log_info "1.4 Verificando acceso cross-account a Log Archive..."

log_info "Asumiendo OrganizationAccountAccessRole en $LOGS_ACCOUNT_ID..."
if creds=$(aws sts assume-role \
  --role-arn "arn:aws:iam::${LOGS_ACCOUNT_ID}:role/OrganizationAccountAccessRole" \
  --role-session-name "lab-verify-access" \
  --query 'Credentials' \
  --output json 2>/dev/null); then

  TEMP_KEY=$(echo "$creds" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKeyId'])")
  TEMP_SECRET=$(echo "$creds" | python3 -c "import sys,json; print(json.load(sys.stdin)['SecretAccessKey'])")
  TEMP_TOKEN=$(echo "$creds" | python3 -c "import sys,json; print(json.load(sys.stdin)['SessionToken'])")

  RESULT=$(AWS_ACCESS_KEY_ID="$TEMP_KEY" \
    AWS_SECRET_ACCESS_KEY="$TEMP_SECRET" \
    AWS_SESSION_TOKEN="$TEMP_TOKEN" \
    aws sts get-caller-identity --query '[Account,Arn]' --output text)

  log_ok "AssumeRole exitoso → $RESULT"
else
  log_warn "AssumeRole falló — la cuenta puede necesitar más tiempo para estar disponible"
  log_warn "Reintentar manualmente: aws sts assume-role --role-arn arn:aws:iam::${LOGS_ACCOUNT_ID}:role/OrganizationAccountAccessRole --role-session-name test"
fi

# -----------------------------------------------------------------------------
# 1.5 Habilitar delegated admin para Config (preparación para Fase 5)
# -----------------------------------------------------------------------------
log_info "1.5 Configurando delegated admin para AWS Config..."

# Verificar si ya está configurado
existing_admin=$(aws organizations list-delegated-administrators \
  --service-principal config.amazonaws.com \
  --query "DelegatedAdministrators[?Id=='${LOGS_ACCOUNT_ID}'].Id" \
  --output text 2>/dev/null)

if [[ -n "$existing_admin" && "$existing_admin" != "None" ]]; then
  log_ok "Delegated admin para Config ya configurado: $LOGS_ACCOUNT_ID"
else
  # Habilitar Config trusted access para la org primero
  aws organizations enable-aws-service-access \
    --service-principal config.amazonaws.com 2>/dev/null || true
  aws organizations enable-aws-service-access \
    --service-principal config-multiaccountsetup.amazonaws.com 2>/dev/null || true

  aws organizations register-delegated-administrator \
    --account-id "$LOGS_ACCOUNT_ID" \
    --service-principal config.amazonaws.com 2>/dev/null || \
    log_warn "Delegated admin para Config: necesita Config habilitado en la cuenta primero (Fase 5)"
fi

# Habilitar también CloudTrail trusted access
aws organizations enable-aws-service-access \
  --service-principal cloudtrail.amazonaws.com 2>/dev/null || true
log_ok "CloudTrail trusted access habilitado"

# -----------------------------------------------------------------------------
# Resumen final
# -----------------------------------------------------------------------------
echo ""
echo "======================================================"
echo " Fase 1 — COMPLETADA"
echo "======================================================"
echo ""
echo "Cuentas en la organización:"
aws organizations list-accounts \
  --query 'Accounts[*].[Name,Id,Status]' \
  --output table

echo ""
echo "OUs creadas:"
echo "  ROOT_ID      : $ROOT_ID"
echo "  OU_SECURITY  : $OU_SECURITY"
echo "  OU_SHARED    : $OU_SHARED"
echo "  OU_WORKLOADS : $OU_WORKLOADS"
echo "  OU_DEV       : $OU_DEV"
echo ""
echo "Cuentas:"
echo "  MGMT_ACCOUNT_ID  : $MGMT_ACCOUNT_ID"
echo "  LOGS_ACCOUNT_ID  : $LOGS_ACCOUNT_ID"
echo ""
log_ok "Estado guardado en: $STATE_FILE"
log_info "Siguiente paso: bash ./cli/02-identity-center.sh"
