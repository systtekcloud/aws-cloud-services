#!/usr/bin/env bash
# =============================================================================
# 04-logging-central.sh — CloudTrail Org Trail + S3 Log Archive + KMS + CW
# Lab: Security & Governance (lab01) — Fase 4
#
# USO: bash ./cli/04-logging-central.sh
# PREREQUISITO: Fases 1-3 completadas, acceso cross-account a Log Archive
# =============================================================================

source "$(dirname "$0")/00-env.sh"

echo "======================================================"
echo " Fase 4 — Logging Centralizado (CloudTrail Org Trail)"
echo "======================================================"

# Verificar valores necesarios
if [[ "$LOGS_ACCOUNT_ID" == "222222222222" ]]; then
  log_error "LOGS_ACCOUNT_ID no configurado. Ejecutar Fase 1 primero."
  exit 1
fi

BUCKET_NAME="org-cloudtrail-logs-${LOGS_ACCOUNT_ID}"
TRAIL_NAME="lab-org-trail"
LOG_GROUP_NAME="/aws/cloudtrail/lab-org-trail"
SNS_TOPIC_NAME="lab-security-alerts"

# -----------------------------------------------------------------------------
# 4.1 KMS CMK en Log Archive Account para cifrar los logs
# -----------------------------------------------------------------------------
log_info "4.1 Creando KMS CMK en Log Archive Account..."

# Asumir rol en Log Archive Account
assume_role "$LOGS_ACCOUNT_ID" "lab-create-logging-infra"

# Verificar si la clave ya existe
existing_key=$(aws kms list-aliases --region eu-west-1 \
  --query "Aliases[?AliasName=='alias/lab-log-archive-key'].TargetKeyId" \
  --output text 2>/dev/null)

if [[ -n "$existing_key" && "$existing_key" != "None" ]]; then
  KMS_LOG_KEY_ARN=$(aws kms describe-key \
    --key-id "alias/lab-log-archive-key" \
    --region eu-west-1 \
    --query 'KeyMetadata.Arn' \
    --output text)
  log_ok "KMS CMK ya existe: $KMS_LOG_KEY_ARN"
else
  # Crear key policy que permite a CloudTrail usar la clave
  KMS_KEY_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowLogsAccountAdmin",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${LOGS_ACCOUNT_ID}:root"
      },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "AllowCloudTrailEncrypt",
      "Effect": "Allow",
      "Principal": {
        "Service": "cloudtrail.amazonaws.com"
      },
      "Action": ["kms:GenerateDataKey*", "kms:Describe*"],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "kms:EncryptionContext:aws:cloudtrail:arn": "arn:aws:cloudtrail:*:${MGMT_ACCOUNT_ID}:trail/*"
        }
      }
    },
    {
      "Sid": "AllowManagementAccountAdmin",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${MGMT_ACCOUNT_ID}:root"
      },
      "Action": [
        "kms:Decrypt",
        "kms:ReEncryptFrom",
        "kms:GenerateDataKey*",
        "kms:DescribeKey"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "kms:CallerAccount": "${MGMT_ACCOUNT_ID}"
        }
      }
    },
    {
      "Sid": "AllowCloudWatchLogs",
      "Effect": "Allow",
      "Principal": {
        "Service": "logs.eu-west-1.amazonaws.com"
      },
      "Action": [
        "kms:Encrypt*",
        "kms:Decrypt*",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:Describe*"
      ],
      "Resource": "*"
    }
  ]
}
EOF
)

  KMS_LOG_KEY_ID=$(aws kms create-key \
    --description "CMK para logs de CloudTrail — lab01" \
    --key-usage ENCRYPT_DECRYPT \
    --policy "$KMS_KEY_POLICY" \
    --region eu-west-1 \
    --query 'KeyMetadata.KeyId' \
    --output text)

  aws kms create-alias \
    --alias-name "alias/lab-log-archive-key" \
    --target-key-id "$KMS_LOG_KEY_ID" \
    --region eu-west-1

  KMS_LOG_KEY_ARN=$(aws kms describe-key \
    --key-id "$KMS_LOG_KEY_ID" \
    --region eu-west-1 \
    --query 'KeyMetadata.Arn' \
    --output text)

  log_ok "KMS CMK creada: $KMS_LOG_KEY_ARN"
fi

# Guardar en estado (necesitamos volver a Management antes de save_state)
KMS_LOG_KEY_ARN_TEMP="$KMS_LOG_KEY_ARN"

# -----------------------------------------------------------------------------
# 4.2 Crear S3 Bucket para logs en Log Archive Account
# -----------------------------------------------------------------------------
log_info "4.2 Creando S3 bucket para logs de CloudTrail..."

# Verificar si el bucket ya existe
if aws s3api head-bucket --bucket "$BUCKET_NAME" --region eu-west-1 &>/dev/null; then
  log_ok "Bucket ya existe: $BUCKET_NAME"
else
  log_info "Creando bucket: $BUCKET_NAME"
  aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region eu-west-1 \
    --create-bucket-configuration LocationConstraint=eu-west-1

  # Bloquear acceso público
  aws s3api put-public-access-block \
    --bucket "$BUCKET_NAME" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  # Habilitar versionado
  aws s3api put-bucket-versioning \
    --bucket "$BUCKET_NAME" \
    --versioning-configuration Status=Enabled

  # Object Lock en modo Governance (7 días)
  aws s3api put-object-lock-configuration \
    --bucket "$BUCKET_NAME" \
    --object-lock-configuration '{
      "ObjectLockEnabled": "Enabled",
      "Rule": {
        "DefaultRetention": {
          "Mode": "GOVERNANCE",
          "Days": 7
        }
      }
    }' 2>/dev/null || log_warn "Object Lock: requiere que el bucket se cree con --object-lock-enabled-for-bucket"

  # Cifrado SSE-KMS con la CMK
  aws s3api put-bucket-encryption \
    --bucket "$BUCKET_NAME" \
    --server-side-encryption-configuration "{
      \"Rules\": [{
        \"ApplyServerSideEncryptionByDefault\": {
          \"SSEAlgorithm\": \"aws:kms\",
          \"KMSMasterKeyID\": \"${KMS_LOG_KEY_ARN_TEMP}\"
        }
      }]
    }"

  log_ok "Bucket creado y configurado: $BUCKET_NAME"
fi

# Aplicar bucket policy para CloudTrail cross-account
log_info "Aplicando bucket policy para CloudTrail org trail..."

BUCKET_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyNonSSL",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${BUCKET_NAME}",
        "arn:aws:s3:::${BUCKET_NAME}/*"
      ],
      "Condition": {
        "Bool": {"aws:SecureTransport": "false"}
      }
    },
    {
      "Sid": "AllowCloudTrailACLCheck",
      "Effect": "Allow",
      "Principal": {"Service": "cloudtrail.amazonaws.com"},
      "Action": "s3:GetBucketAcl",
      "Resource": "arn:aws:s3:::${BUCKET_NAME}",
      "Condition": {
        "StringEquals": {
          "aws:SourceArn": "arn:aws:cloudtrail:eu-west-1:${MGMT_ACCOUNT_ID}:trail/${TRAIL_NAME}"
        }
      }
    },
    {
      "Sid": "AllowCloudTrailOrgWrite",
      "Effect": "Allow",
      "Principal": {"Service": "cloudtrail.amazonaws.com"},
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/AWSLogs/${MGMT_ACCOUNT_ID}/*",
      "Condition": {
        "StringEquals": {
          "s3:x-amz-acl": "bucket-owner-full-control",
          "aws:SourceArn": "arn:aws:cloudtrail:eu-west-1:${MGMT_ACCOUNT_ID}:trail/${TRAIL_NAME}"
        }
      }
    },
    {
      "Sid": "AllowCloudTrailOrgAccountsWrite",
      "Effect": "Allow",
      "Principal": {"Service": "cloudtrail.amazonaws.com"},
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/AWSLogs/o-*/*",
      "Condition": {
        "StringEquals": {
          "s3:x-amz-acl": "bucket-owner-full-control"
        }
      }
    },
    {
      "Sid": "DenyDeleteObjects",
      "Effect": "Deny",
      "Principal": "*",
      "Action": [
        "s3:DeleteObject",
        "s3:DeleteObjectVersion",
        "s3:DeleteBucket"
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

aws s3api put-bucket-policy \
  --bucket "$BUCKET_NAME" \
  --policy "$BUCKET_POLICY"
log_ok "Bucket policy aplicada"

# Volver a Management Account
restore_mgmt_account

# Guardar estado desde Management Account
save_state "KMS_LOG_KEY_ARN" "$KMS_LOG_KEY_ARN_TEMP"
save_state "BUCKET_NAME" "$BUCKET_NAME"
export KMS_LOG_KEY_ARN="$KMS_LOG_KEY_ARN_TEMP"

# -----------------------------------------------------------------------------
# 4.3 IAM Role para CloudTrail → CloudWatch Logs (en Management Account)
# -----------------------------------------------------------------------------
log_info "4.3 Creando IAM Role para CloudTrail → CloudWatch..."

CLOUDTRAIL_CW_ROLE="lab-cloudtrail-cloudwatch-role"

if aws iam get-role --role-name "$CLOUDTRAIL_CW_ROLE" &>/dev/null; then
  log_ok "IAM Role ya existe: $CLOUDTRAIL_CW_ROLE"
else
  CW_TRUST_POLICY=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "cloudtrail.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
)

  aws iam create-role \
    --role-name "$CLOUDTRAIL_CW_ROLE" \
    --assume-role-policy-document "$CW_TRUST_POLICY" \
    --description "Permite a CloudTrail escribir en CloudWatch Logs"

  CW_LOG_GROUP_ARN="arn:aws:logs:eu-west-1:${MGMT_ACCOUNT_ID}:log-group:${LOG_GROUP_NAME}:*"
  CW_ROLE_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ],
    "Resource": "${CW_LOG_GROUP_ARN}"
  }]
}
EOF
)

  aws iam put-role-policy \
    --role-name "$CLOUDTRAIL_CW_ROLE" \
    --policy-name "CloudTrailToCloudWatch" \
    --policy-document "$CW_ROLE_POLICY"

  log_ok "IAM Role creado: $CLOUDTRAIL_CW_ROLE"
fi

CLOUDTRAIL_CW_ROLE_ARN=$(aws iam get-role \
  --role-name "$CLOUDTRAIL_CW_ROLE" \
  --query 'Role.Arn' --output text)

# -----------------------------------------------------------------------------
# 4.4 Crear CloudWatch Log Group
# -----------------------------------------------------------------------------
log_info "4.4 Creando CloudWatch Log Group..."

aws logs create-log-group \
  --log-group-name "$LOG_GROUP_NAME" \
  --region eu-west-1 2>/dev/null || \
  log_ok "Log Group ya existe: $LOG_GROUP_NAME"

aws logs put-retention-policy \
  --log-group-name "$LOG_GROUP_NAME" \
  --retention-in-days 90 \
  --region eu-west-1
log_ok "Retención configurada: 90 días"

# -----------------------------------------------------------------------------
# 4.5 Crear Organization Trail
# -----------------------------------------------------------------------------
log_info "4.5 Creando Organization Trail..."

# Verificar si el trail ya existe
existing_trail=$(aws cloudtrail describe-trails \
  --include-shadow-trails false \
  --query "trailList[?Name=='${TRAIL_NAME}'].Name" \
  --output text 2>/dev/null)

if [[ -n "$existing_trail" && "$existing_trail" != "None" ]]; then
  log_ok "Trail ya existe: $TRAIL_NAME"
else
  log_info "Creando trail org: $TRAIL_NAME → s3://$BUCKET_NAME"

  aws cloudtrail create-trail \
    --name "$TRAIL_NAME" \
    --s3-bucket-name "$BUCKET_NAME" \
    --is-multi-region-trail \
    --is-organization-trail \
    --enable-log-file-validation \
    --kms-key-id "$KMS_LOG_KEY_ARN" \
    --cloud-watch-logs-log-group-arn "arn:aws:logs:eu-west-1:${MGMT_ACCOUNT_ID}:log-group:${LOG_GROUP_NAME}" \
    --cloud-watch-logs-role-arn "$CLOUDTRAIL_CW_ROLE_ARN" \
    --region eu-west-1

  log_ok "Trail creado: $TRAIL_NAME"
fi

# Habilitar Data Events para S3 (opcional — tiene coste)
# aws cloudtrail put-event-selectors --trail-name "$TRAIL_NAME" \
#   --event-selectors '[{"ReadWriteType":"All","IncludeManagementEvents":true,"DataResources":[{"Type":"AWS::S3::Object","Values":["arn:aws:s3"]}]}]'

# Iniciar logging
aws cloudtrail start-logging --name "$TRAIL_NAME" --region eu-west-1
log_ok "Trail logging iniciado"

# -----------------------------------------------------------------------------
# 4.6 CloudWatch: Metric Filter + Alarm para cambios IAM
# -----------------------------------------------------------------------------
log_info "4.6 Configurando Metric Filter y Alarm para cambios IAM..."

METRIC_NAMESPACE="SecurityMetrics/IAM"
METRIC_NAME="IAMPolicyChanges"
ALARM_NAME="lab-iam-changes"

# Metric Filter
aws logs put-metric-filter \
  --log-group-name "$LOG_GROUP_NAME" \
  --filter-name "IAMChanges" \
  --filter-pattern '{ ($.eventName = CreateUser) || ($.eventName = DeleteUser) || ($.eventName = CreateRole) || ($.eventName = DeleteRole) || ($.eventName = CreatePolicy) || ($.eventName = DeletePolicy) || ($.eventName = AttachRolePolicy) || ($.eventName = DetachRolePolicy) || ($.eventName = CreateAccessKey) || ($.eventName = DeleteAccessKey) }' \
  --metric-transformations "[{
    \"metricName\": \"${METRIC_NAME}\",
    \"metricNamespace\": \"${METRIC_NAMESPACE}\",
    \"metricValue\": \"1\",
    \"defaultValue\": 0
  }]" \
  --region eu-west-1 2>/dev/null && \
  log_ok "Metric Filter creado: IAMChanges" || \
  log_warn "Metric Filter — ya existe"

# SNS Topic para alertas
SNS_TOPIC_ARN=$(aws sns list-topics \
  --region eu-west-1 \
  --query "Topics[?ends_with(TopicArn,'${SNS_TOPIC_NAME}')].TopicArn" \
  --output text 2>/dev/null)

if [[ -z "$SNS_TOPIC_ARN" || "$SNS_TOPIC_ARN" == "None" ]]; then
  SNS_TOPIC_ARN=$(aws sns create-topic \
    --name "$SNS_TOPIC_NAME" \
    --region eu-west-1 \
    --query 'TopicArn' --output text)
  log_ok "SNS Topic creado: $SNS_TOPIC_ARN"

  # Suscribir email (requiere confirmación manual)
  ALERT_EMAIL="${LAB_EMAIL_BASE//@/+alerts@}"
  aws sns subscribe \
    --topic-arn "$SNS_TOPIC_ARN" \
    --protocol email \
    --notification-endpoint "$ALERT_EMAIL" \
    --region eu-west-1 &>/dev/null
  log_warn "Revisar email '$ALERT_EMAIL' para confirmar suscripción SNS"
else
  log_ok "SNS Topic ya existe: $SNS_TOPIC_ARN"
fi

save_state "SNS_TOPIC_ARN" "$SNS_TOPIC_ARN"

# CloudWatch Alarm
aws cloudwatch put-metric-alarm \
  --alarm-name "$ALARM_NAME" \
  --alarm-description "Alerta: cambio detectado en IAM (lab01)" \
  --metric-name "$METRIC_NAME" \
  --namespace "$METRIC_NAMESPACE" \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions "$SNS_TOPIC_ARN" \
  --treat-missing-data notBreaching \
  --region eu-west-1 2>/dev/null && \
  log_ok "CloudWatch Alarm creada: $ALARM_NAME" || \
  log_warn "CloudWatch Alarm — ya existe"

# -----------------------------------------------------------------------------
# 4.7 Verificación
# -----------------------------------------------------------------------------
echo ""
log_info "4.7 Verificando configuración..."

echo ""
log_info "Estado del trail:"
aws cloudtrail get-trail-status \
  --name "$TRAIL_NAME" \
  --region eu-west-1 \
  --query '[IsLogging,LatestDeliveryError,LatestCloudWatchLogsDeliveryTime]' \
  --output table

echo ""
log_info "Para verificar que llegan eventos (esperar ~5 min tras una acción):"
echo "  # Ver últimos eventos en CloudTrail"
echo "  aws cloudtrail lookup-events --max-results 5 --region eu-west-1"
echo ""
echo "  # Ver logs en CloudWatch"
echo "  aws logs filter-log-events \\"
echo "    --log-group-name '$LOG_GROUP_NAME' \\"
echo "    --start-time \$(date -d '10 minutes ago' +%s)000 \\"
echo "    --filter-pattern '{ $.eventSource = \"iam.amazonaws.com\" }' \\"
echo "    --region eu-west-1 --max-items 5"

# -----------------------------------------------------------------------------
# Resumen
# -----------------------------------------------------------------------------
echo ""
echo "======================================================"
echo " Fase 4 — COMPLETADA"
echo "======================================================"
echo ""
echo "  TRAIL_NAME      : $TRAIL_NAME"
echo "  BUCKET_NAME     : $BUCKET_NAME"
echo "  LOG_GROUP       : $LOG_GROUP_NAME"
echo "  KMS_LOG_KEY_ARN : $KMS_LOG_KEY_ARN"
echo "  SNS_TOPIC_ARN   : $SNS_TOPIC_ARN"
echo ""
log_ok "Estado guardado en: $STATE_FILE"
log_info "Siguiente paso: bash ./cli/05-config.sh"
