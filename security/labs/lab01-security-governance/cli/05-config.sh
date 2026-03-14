#!/usr/bin/env bash
# =============================================================================
# 05-config.sh — AWS Config: Recorder + Delivery Channel + Aggregator + Rules
# Lab: Security & Governance (lab01) — Fase 5
#
# USO: bash ./cli/05-config.sh
# PREREQUISITO: Fases 1-4 completadas
# =============================================================================

source "$(dirname "$0")/00-env.sh"

echo "======================================================"
echo " Fase 5 — AWS Config (Compliance & Visibility)"
echo "======================================================"

if [[ "$LOGS_ACCOUNT_ID" == "222222222222" ]]; then
  log_error "LOGS_ACCOUNT_ID no configurado. Ejecutar Fase 1 primero."
  exit 1
fi

BUCKET_NAME="${BUCKET_NAME:-org-cloudtrail-logs-${LOGS_ACCOUNT_ID}}"
CONFIG_ROLE="lab-config-recorder-role"
CONFIG_RECORDER_NAME="lab-config-recorder"
CONFIG_DELIVERY_CHANNEL="lab-config-delivery"
CONFIG_AGGREGATOR="lab-org-aggregator"

# -----------------------------------------------------------------------------
# 5.1 IAM Role para Config Recorder
# -----------------------------------------------------------------------------
log_info "5.1 Creando IAM Role para Config Recorder..."

if aws iam get-role --role-name "$CONFIG_ROLE" &>/dev/null; then
  log_ok "IAM Role ya existe: $CONFIG_ROLE"
else
  CONFIG_TRUST_POLICY=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "config.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
)

  aws iam create-role \
    --role-name "$CONFIG_ROLE" \
    --assume-role-policy-document "$CONFIG_TRUST_POLICY" \
    --description "IAM Role para AWS Config Recorder — lab01"

  # Adjuntar la política managed de Config
  aws iam attach-role-policy \
    --role-name "$CONFIG_ROLE" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"

  # Política adicional para S3 en Log Archive Account (cross-account)
  CONFIG_S3_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetBucketAcl"
      ],
      "Resource": [
        "arn:aws:s3:::${BUCKET_NAME}",
        "arn:aws:s3:::${BUCKET_NAME}/*"
      ]
    }
  ]
}
EOF
)

  aws iam put-role-policy \
    --role-name "$CONFIG_ROLE" \
    --policy-name "ConfigS3CrossAccount" \
    --policy-document "$CONFIG_S3_POLICY"

  log_ok "IAM Role creado: $CONFIG_ROLE"
fi

CONFIG_ROLE_ARN=$(aws iam get-role \
  --role-name "$CONFIG_ROLE" \
  --query 'Role.Arn' --output text)

# -----------------------------------------------------------------------------
# 5.2 Config Recorder
# -----------------------------------------------------------------------------
log_info "5.2 Configurando Config Recorder..."

aws configservice put-configuration-recorder \
  --configuration-recorder "{
    \"name\": \"${CONFIG_RECORDER_NAME}\",
    \"roleARN\": \"${CONFIG_ROLE_ARN}\",
    \"recordingGroup\": {
      \"allSupported\": true,
      \"includeGlobalResourceTypes\": true
    }
  }" \
  --region eu-west-1

log_ok "Config Recorder configurado: $CONFIG_RECORDER_NAME"

# -----------------------------------------------------------------------------
# 5.3 Delivery Channel (entrega a S3 en Log Archive Account)
# -----------------------------------------------------------------------------
log_info "5.3 Configurando Config Delivery Channel..."

# Necesitamos añadir permisos S3 al bucket de logs para Config
log_info "Añadiendo permisos Config al bucket de logs (en Log Archive Account)..."
assume_role "$LOGS_ACCOUNT_ID" "lab-config-s3-policy"

# Obtener la política actual del bucket
current_policy=$(aws s3api get-bucket-policy \
  --bucket "$BUCKET_NAME" \
  --query 'Policy' --output text 2>/dev/null || echo '{"Version":"2012-10-17","Statement":[]}')

# Añadir statement para Config si no existe ya
CONFIG_BUCKET_STMT=$(cat <<EOF
{
  "Sid": "AllowConfigDelivery",
  "Effect": "Allow",
  "Principal": {"Service": "config.amazonaws.com"},
  "Action": [
    "s3:PutObject",
    "s3:GetBucketAcl"
  ],
  "Resource": [
    "arn:aws:s3:::${BUCKET_NAME}",
    "arn:aws:s3:::${BUCKET_NAME}/AWSLogs/${MGMT_ACCOUNT_ID}/Config/*"
  ],
  "Condition": {
    "StringEquals": {
      "s3:x-amz-acl": "bucket-owner-full-control"
    }
  }
}
EOF
)

# Usar python3 para combinar policies de forma segura
combined_policy=$(python3 - <<PYEOF
import json, sys

current = json.loads('''${current_policy}''')
new_stmt = json.loads('''${CONFIG_BUCKET_STMT}''')

# Eliminar statement si ya existe
current['Statement'] = [s for s in current['Statement'] if s.get('Sid') != 'AllowConfigDelivery']
current['Statement'].append(new_stmt)

print(json.dumps(current))
PYEOF
)

aws s3api put-bucket-policy \
  --bucket "$BUCKET_NAME" \
  --policy "$combined_policy"
log_ok "Permisos Config añadidos al bucket"

restore_mgmt_account

# Crear Delivery Channel
aws configservice put-delivery-channel \
  --delivery-channel "{
    \"name\": \"${CONFIG_DELIVERY_CHANNEL}\",
    \"s3BucketName\": \"${BUCKET_NAME}\",
    \"s3KeyPrefix\": \"config\",
    \"configSnapshotDeliveryProperties\": {
      \"deliveryFrequency\": \"TwentyFour_Hours\"
    }
  }" \
  --region eu-west-1

log_ok "Config Delivery Channel configurado → s3://$BUCKET_NAME/config/"

# -----------------------------------------------------------------------------
# 5.4 Iniciar Config Recorder
# -----------------------------------------------------------------------------
log_info "5.4 Iniciando Config Recorder..."

aws configservice start-configuration-recorder \
  --configuration-recorder-name "$CONFIG_RECORDER_NAME" \
  --region eu-west-1

log_ok "Config Recorder iniciado"

# Verificar estado
STATUS=$(aws configservice describe-configuration-recorder-status \
  --configuration-recorder-names "$CONFIG_RECORDER_NAME" \
  --region eu-west-1 \
  --query 'ConfigurationRecordersStatus[0].recording' \
  --output text 2>/dev/null)
log_ok "Recording activo: $STATUS"

# -----------------------------------------------------------------------------
# 5.5 Config Aggregator Org-level
# -----------------------------------------------------------------------------
log_info "5.5 Creando Config Aggregator a nivel de organización..."

existing_aggregator=$(aws configservice describe-configuration-aggregators \
  --region eu-west-1 \
  --query "ConfigurationAggregators[?ConfigurationAggregatorName=='${CONFIG_AGGREGATOR}'].ConfigurationAggregatorName" \
  --output text 2>/dev/null)

if [[ -n "$existing_aggregator" && "$existing_aggregator" != "None" ]]; then
  log_ok "Config Aggregator ya existe: $CONFIG_AGGREGATOR"
else
  aws configservice put-configuration-aggregator \
    --configuration-aggregator-name "$CONFIG_AGGREGATOR" \
    --organization-aggregation-source "{
      \"RoleArn\": \"${CONFIG_ROLE_ARN}\",
      \"AllAwsRegions\": false,
      \"AwsRegions\": [\"eu-west-1\"]
    }" \
    --region eu-west-1 2>/dev/null && \
    log_ok "Config Aggregator creado: $CONFIG_AGGREGATOR" || \
    log_warn "Config Aggregator: puede requerir delegated admin configurado en Fase 1"
fi

# -----------------------------------------------------------------------------
# 5.6 Config Rules
# -----------------------------------------------------------------------------
log_info "5.6 Creando Config Rules..."

create_config_rule() {
  local rule_name="$1"
  local source_identifier="$2"
  local description="$3"

  aws configservice put-config-rule \
    --config-rule "{
      \"ConfigRuleName\": \"${rule_name}\",
      \"Description\": \"${description}\",
      \"Source\": {
        \"Owner\": \"AWS\",
        \"SourceIdentifier\": \"${source_identifier}\"
      }
    }" \
    --region eu-west-1 2>/dev/null && \
    log_ok "Rule creada: $rule_name" || \
    log_warn "Rule '$rule_name' — ya existe"
}

create_config_rule \
  "s3-bucket-public-read-prohibited" \
  "S3_BUCKET_PUBLIC_READ_PROHIBITED" \
  "Detecta buckets S3 con acceso público de lectura habilitado"

create_config_rule \
  "encrypted-volumes" \
  "ENCRYPTED_VOLUMES" \
  "Detecta volúmenes EBS no cifrados adjuntos a instancias EC2"

create_config_rule \
  "mfa-enabled-for-iam-console-access" \
  "MFA_ENABLED_FOR_IAM_CONSOLE_ACCESS" \
  "Detecta usuarios IAM con acceso a consola sin MFA habilitado"

create_config_rule \
  "root-account-mfa-enabled" \
  "ROOT_ACCOUNT_MFA_ENABLED" \
  "Detecta si la cuenta root tiene MFA habilitado"

create_config_rule \
  "cloudtrail-enabled" \
  "CLOUD_TRAIL_ENABLED" \
  "Verifica que CloudTrail está habilitado"

# -----------------------------------------------------------------------------
# 5.7 Forzar evaluación no-compliant para demostración
# -----------------------------------------------------------------------------
log_info "5.7 Preparando recurso no-compliant para demostración..."

echo ""
log_warn "Para demostrar la regla s3-bucket-public-read-prohibited:"
echo "  # Crear bucket de prueba (ajustar nombre único)"
echo "  TEST_BUCKET=\"test-config-\$(date +%s)\""
echo "  aws s3api create-bucket --bucket \"\$TEST_BUCKET\" --region eu-west-1 \\"
echo "    --create-bucket-configuration LocationConstraint=eu-west-1"
echo "  # Desactivar Block Public Access (viola la política SCP + Config Rule)"
echo "  aws s3api put-public-access-block --bucket \"\$TEST_BUCKET\" \\"
echo "    --public-access-block-configuration BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"
echo "  # Disparar evaluación manual"
echo "  aws configservice start-config-rules-evaluation --config-rule-names s3-bucket-public-read-prohibited"
echo "  # Ver resultados (esperar ~1-2 min)"
echo "  aws configservice get-compliance-details-by-config-rule --config-rule-name s3-bucket-public-read-prohibited \\"
echo "    --query 'EvaluationResults[?ComplianceType==\`NON_COMPLIANT\`]'"
echo ""
echo "  # Limpiar bucket de prueba"
echo "  aws s3api delete-bucket --bucket \"\$TEST_BUCKET\" --region eu-west-1"

# -----------------------------------------------------------------------------
# Verificación
# -----------------------------------------------------------------------------
echo ""
log_info "Estado actual de Config Recorder:"
aws configservice describe-configuration-recorder-status \
  --region eu-west-1 \
  --query 'ConfigurationRecordersStatus[*].[name,recording,lastStatus]' \
  --output table

echo ""
log_info "Config Rules activas:"
aws configservice describe-config-rules \
  --region eu-west-1 \
  --query 'ConfigRules[*].[ConfigRuleName,ConfigRuleState]' \
  --output table

echo ""
log_info "Compliance summary (puede tardar unos minutos en tener datos):"
aws configservice get-compliance-summary-by-config-rule \
  --region eu-west-1 \
  --query 'ComplianceSummariesByConfigRule[*].[ConfigRuleName,Compliance.ComplianceType]' \
  --output table 2>/dev/null || log_warn "Sin datos aún — esperar que Config evalúe los recursos"

# -----------------------------------------------------------------------------
# Resumen
# -----------------------------------------------------------------------------
echo ""
echo "======================================================"
echo " Fase 5 — COMPLETADA"
echo "======================================================"
echo ""
echo "  CONFIG_RECORDER  : $CONFIG_RECORDER_NAME"
echo "  DELIVERY_CHANNEL : $CONFIG_DELIVERY_CHANNEL"
echo "  AGGREGATOR       : $CONFIG_AGGREGATOR"
echo "  BUCKET           : s3://$BUCKET_NAME/config/"
echo "  Rules            : s3-bucket-public-read-prohibited, encrypted-volumes,"
echo "                     mfa-enabled-for-iam-console-access, root-account-mfa-enabled,"
echo "                     cloudtrail-enabled"
echo ""
log_info "Diferencia clave CloudTrail vs Config:"
echo "  CloudTrail → QUIEN hizo QUÉ (API calls, auditoria temporal)"
echo "  Config     → CÓMO están los recursos AHORA (estado, historial, compliance)"
echo ""
log_ok "Estado guardado en: $STATE_FILE"
log_info "Siguiente paso: bash ./cli/06-secretos-ssm.sh"
