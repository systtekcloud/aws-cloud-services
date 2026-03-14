#!/usr/bin/env bash
# =============================================================================
# 06-secretos-ssm.sh — KMS + Secrets Manager + SSM + EC2 (IMDSv2 + Session Mgr)
# Lab: Security & Governance (lab01) — Fase 6
#
# USO: bash ./cli/06-secretos-ssm.sh
# PREREQUISITO: Fases 1-5 completadas
# =============================================================================

source "$(dirname "$0")/00-env.sh"

echo "======================================================"
echo " Fase 6 — Secretos y Operación Segura"
echo "======================================================"

APP_KMS_ALIAS="alias/lab-app-secrets"
SECRET_NAME="lab/db/credentials"
SSM_PARAM_DB_HOST="/lab/config/db-host"
SSM_PARAM_ENV="/lab/config/environment"
IAM_ROLE_NAME="lab-app-role"
IAM_INSTANCE_PROFILE="lab-app-profile"
SG_NAME="lab-app-sg"

# Obtener AMI más reciente de Amazon Linux 2023 en eu-west-1
get_latest_ami() {
  aws ec2 describe-images \
    --owners amazon \
    --filters \
      "Name=name,Values=al2023-ami-2023*-x86_64" \
      "Name=state,Values=available" \
    --region eu-west-1 \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text 2>/dev/null
}

# -----------------------------------------------------------------------------
# 6.1 KMS CMK para secretos de la aplicación
# -----------------------------------------------------------------------------
log_info "6.1 Creando KMS CMK para secretos de la aplicación..."

existing_kms=$(aws kms list-aliases --region eu-west-1 \
  --query "Aliases[?AliasName=='${APP_KMS_ALIAS}'].TargetKeyId" \
  --output text 2>/dev/null)

if [[ -n "$existing_kms" && "$existing_kms" != "None" ]]; then
  KMS_APP_KEY_ARN=$(aws kms describe-key \
    --key-id "$APP_KMS_ALIAS" \
    --region eu-west-1 \
    --query 'KeyMetadata.Arn' --output text)
  log_ok "KMS CMK ya existe: $KMS_APP_KEY_ARN"
else
  APP_KEY_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowManagementAccountAdmin",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${MGMT_ACCOUNT_ID}:root"
      },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "AllowSecretsManagerService",
      "Effect": "Allow",
      "Principal": {
        "Service": "secretsmanager.amazonaws.com"
      },
      "Action": [
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:Encrypt",
        "kms:ReEncrypt*",
        "kms:DescribeKey"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowSSMService",
      "Effect": "Allow",
      "Principal": {
        "Service": "ssm.amazonaws.com"
      },
      "Action": [
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:Encrypt",
        "kms:DescribeKey"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowEC2AppRole",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${MGMT_ACCOUNT_ID}:role/${IAM_ROLE_NAME}"
      },
      "Action": [
        "kms:Decrypt",
        "kms:DescribeKey"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": [
            "secretsmanager.eu-west-1.amazonaws.com",
            "ssm.eu-west-1.amazonaws.com"
          ]
        }
      }
    }
  ]
}
EOF
)

  KMS_APP_KEY_ID=$(aws kms create-key \
    --description "CMK para secretos de aplicación — lab01" \
    --key-usage ENCRYPT_DECRYPT \
    --policy "$APP_KEY_POLICY" \
    --region eu-west-1 \
    --query 'KeyMetadata.KeyId' --output text)

  aws kms create-alias \
    --alias-name "$APP_KMS_ALIAS" \
    --target-key-id "$KMS_APP_KEY_ID" \
    --region eu-west-1

  aws kms tag-resource \
    --key-id "$KMS_APP_KEY_ID" \
    --tags "TagKey=${LAB_TAG_KEY},TagValue=${LAB_TAG_VALUE}" \
    --region eu-west-1

  KMS_APP_KEY_ARN=$(aws kms describe-key \
    --key-id "$KMS_APP_KEY_ID" \
    --region eu-west-1 \
    --query 'KeyMetadata.Arn' --output text)

  log_ok "KMS CMK creada: $KMS_APP_KEY_ARN"
fi

save_state "KMS_APP_KEY_ARN" "$KMS_APP_KEY_ARN"

# -----------------------------------------------------------------------------
# 6.2 IAM Role para EC2 con mínimo privilegio
# -----------------------------------------------------------------------------
log_info "6.2 Creando IAM Role para EC2..."

if aws iam get-role --role-name "$IAM_ROLE_NAME" &>/dev/null; then
  log_ok "IAM Role ya existe: $IAM_ROLE_NAME"
else
  EC2_TRUST_POLICY=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
)

  aws iam create-role \
    --role-name "$IAM_ROLE_NAME" \
    --assume-role-policy-document "$EC2_TRUST_POLICY" \
    --description "Rol de aplicación — acceso a Secrets Manager y SSM vía KMS"

  # Adjuntar SSM Core para Session Manager
  aws iam attach-role-policy \
    --role-name "$IAM_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

  # Policy inline con kms:ViaService para restringir el uso de KMS
  APP_INLINE_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowSecretsManagerAccess",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:eu-west-1:${MGMT_ACCOUNT_ID}:secret:lab/*"
    },
    {
      "Sid": "AllowSSMParameterAccess",
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ],
      "Resource": "arn:aws:ssm:eu-west-1:${MGMT_ACCOUNT_ID}:parameter/lab/*"
    },
    {
      "Sid": "AllowKMSViaServiceOnly",
      "Effect": "Allow",
      "Action": [
        "kms:Decrypt",
        "kms:DescribeKey"
      ],
      "Resource": "${KMS_APP_KEY_ARN}",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": [
            "secretsmanager.eu-west-1.amazonaws.com",
            "ssm.eu-west-1.amazonaws.com"
          ]
        }
      }
    }
  ]
}
EOF
)

  aws iam put-role-policy \
    --role-name "$IAM_ROLE_NAME" \
    --policy-name "lab-app-minimal-policy" \
    --policy-document "$APP_INLINE_POLICY"

  log_ok "IAM Role creado: $IAM_ROLE_NAME"
fi

# Crear Instance Profile
if ! aws iam get-instance-profile --instance-profile-name "$IAM_INSTANCE_PROFILE" &>/dev/null; then
  aws iam create-instance-profile \
    --instance-profile-name "$IAM_INSTANCE_PROFILE"
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$IAM_INSTANCE_PROFILE" \
    --role-name "$IAM_ROLE_NAME"
  log_ok "Instance Profile creado: $IAM_INSTANCE_PROFILE"
  sleep 10  # IAM eventual consistency
else
  log_ok "Instance Profile ya existe: $IAM_INSTANCE_PROFILE"
fi

# -----------------------------------------------------------------------------
# 6.3 Secrets Manager — Crear secreto cifrado con CMK
# -----------------------------------------------------------------------------
log_info "6.3 Creando secreto en Secrets Manager..."

existing_secret=$(aws secretsmanager describe-secret \
  --secret-id "$SECRET_NAME" \
  --region eu-west-1 \
  --query 'ARN' --output text 2>/dev/null)

if [[ -n "$existing_secret" && "$existing_secret" != "None" ]]; then
  SECRET_ARN="$existing_secret"
  log_ok "Secreto ya existe: $SECRET_ARN"
else
  SECRET_ARN=$(aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --description "Credenciales de base de datos — lab01 (cifradas con CMK)" \
    --kms-key-id "$KMS_APP_KEY_ARN" \
    --secret-string '{
      "username": "lab_admin",
      "password": "S3cur3P@ssw0rd!",
      "host": "db.internal.lab",
      "port": 5432,
      "dbname": "labapp"
    }' \
    --region eu-west-1 \
    --tags "Key=${LAB_TAG_KEY},Value=${LAB_TAG_VALUE}" \
    --query 'ARN' --output text)

  log_ok "Secreto creado: $SECRET_ARN"
fi

save_state "SECRET_ARN" "$SECRET_ARN"

# -----------------------------------------------------------------------------
# 6.4 SSM Parameter Store
# -----------------------------------------------------------------------------
log_info "6.4 Creando parámetros en SSM Parameter Store..."

# SecureString (cifrado con CMK)
aws ssm put-parameter \
  --name "$SSM_PARAM_DB_HOST" \
  --value "db.internal.lab" \
  --type "SecureString" \
  --key-id "$KMS_APP_KEY_ARN" \
  --description "Host de base de datos (SecureString cifrado con CMK)" \
  --region eu-west-1 \
  --overwrite 2>/dev/null && \
  log_ok "SSM SecureString creado: $SSM_PARAM_DB_HOST" || \
  log_warn "SSM SecureString — ya existe"

# String plano (no cifrado)
aws ssm put-parameter \
  --name "$SSM_PARAM_ENV" \
  --value "development" \
  --type "String" \
  --description "Entorno de despliegue (String plano)" \
  --region eu-west-1 \
  --overwrite 2>/dev/null && \
  log_ok "SSM String creado: $SSM_PARAM_ENV" || \
  log_warn "SSM String — ya existe"

# -----------------------------------------------------------------------------
# 6.5 Security Group para EC2 (sin puerto 22 — SSM Session Manager)
# -----------------------------------------------------------------------------
log_info "6.5 Creando Security Group..."

# Obtener VPC por defecto
DEFAULT_VPC=$(aws ec2 describe-vpcs \
  --filters "Name=is-default,Values=true" \
  --region eu-west-1 \
  --query 'Vpcs[0].VpcId' --output text)

existing_sg=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${DEFAULT_VPC}" \
  --region eu-west-1 \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

if [[ -n "$existing_sg" && "$existing_sg" != "None" ]]; then
  SG_ID="$existing_sg"
  log_ok "Security Group ya existe: $SG_ID"
else
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "SG para EC2 lab-app — solo egress HTTPS para SSM (sin SSH)" \
    --vpc-id "$DEFAULT_VPC" \
    --region eu-west-1 \
    --query 'GroupId' --output text)

  aws ec2 create-tags \
    --resources "$SG_ID" \
    --tags "Key=${LAB_TAG_KEY},Value=${LAB_TAG_VALUE}" \
    --region eu-west-1

  # Eliminar la regla de ingress por defecto (rango 0.0.0.0/0 que no debe existir)
  aws ec2 revoke-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol all \
    --cidr 0.0.0.0/0 \
    --region eu-west-1 2>/dev/null || true

  # Egress: solo HTTPS (443) para SSM endpoints
  # (SSM usa ssm.amazonaws.com, ssmmessages.amazonaws.com, ec2messages.amazonaws.com)
  aws ec2 authorize-security-group-egress \
    --group-id "$SG_ID" \
    --ip-permissions '[{
      "IpProtocol": "tcp",
      "FromPort": 443,
      "ToPort": 443,
      "IpRanges": [{"CidrIp": "0.0.0.0/0", "Description": "HTTPS para endpoints SSM"}]
    }]' \
    --region eu-west-1

  log_ok "Security Group creado: $SG_ID (solo egress HTTPS 443, sin SSH)"
fi

save_state "SG_ID" "$SG_ID"

# -----------------------------------------------------------------------------
# 6.6 Lanzar instancia EC2 con IMDSv2 y Session Manager
# -----------------------------------------------------------------------------
log_info "6.6 Lanzando instancia EC2..."

existing_instance=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:Project,Values=${LAB_TAG_VALUE}" \
    "Name=instance-state-name,Values=running,stopped,pending" \
  --region eu-west-1 \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text 2>/dev/null)

if [[ -n "$existing_instance" && "$existing_instance" != "None" ]]; then
  INSTANCE_ID="$existing_instance"
  log_ok "Instancia EC2 ya existe: $INSTANCE_ID"
else
  AMI_ID=$(get_latest_ami)
  log_info "AMI seleccionada: $AMI_ID"

  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "t3.micro" \
    --iam-instance-profile "Name=${IAM_INSTANCE_PROFILE}" \
    --security-group-ids "$SG_ID" \
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=${LAB_TAG_KEY},Value=${LAB_TAG_VALUE}},{Key=Name,Value=lab-app-server}]" \
    --region eu-west-1 \
    --query 'Instances[0].InstanceId' \
    --output text)

  log_ok "Instancia lanzada: $INSTANCE_ID"
  log_info "Esperando que la instancia esté running..."
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region eu-west-1
  log_ok "Instancia running: $INSTANCE_ID"
fi

save_state "INSTANCE_ID" "$INSTANCE_ID"

# -----------------------------------------------------------------------------
# 6.7 Verificaciones
# -----------------------------------------------------------------------------
log_info "6.7 Verificaciones de seguridad..."

echo ""
log_info "Esperando que SSM registre la instancia (~1-2 min)..."
for i in $(seq 1 12); do
  SSM_STATUS=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
    --region eu-west-1 \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text 2>/dev/null)
  echo "  Intento $i/12 — SSM status: ${SSM_STATUS:-pendiente}"
  [[ "$SSM_STATUS" == "Online" ]] && break
  sleep 10
done

echo ""
if [[ "$SSM_STATUS" == "Online" ]]; then
  log_ok "SSM Session Manager disponible para $INSTANCE_ID"
  echo "  Iniciar sesión: aws ssm start-session --target $INSTANCE_ID --region eu-west-1"
else
  log_warn "SSM aún no disponible. Verificar:"
  echo "  1. El SG permite egress HTTPS 443"
  echo "  2. La subnet tiene ruta a Internet (o VPC Endpoints para SSM)"
  echo "  3. IAM Role tiene AmazonSSMManagedInstanceCore"
  echo "  4. La instancia está en región eu-west-1"
fi

echo ""
log_info "Verificando IMDSv2 (HttpTokens=required):"
echo "  # Estos comandos ejecutar desde dentro de la instancia (SSM Session):"
echo ""
echo "  # IMDSv1 — DEBE FALLAR (sin token)"
echo "  curl -s http://169.254.169.254/latest/meta-data/instance-id"
echo ""
echo "  # IMDSv2 — DEBE FUNCIONAR"
echo "  TOKEN=\$(curl -s -X PUT 'http://169.254.169.254/latest/api/token' \\"
echo "    -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')"
echo "  curl -s -H \"X-aws-ec2-metadata-token: \$TOKEN\" \\"
echo "    http://169.254.169.254/latest/meta-data/instance-id"

echo ""
log_info "Comandos de verificación para ejecutar en la instancia:"
echo ""
echo "  # Leer secreto desde Secrets Manager (usando rol EC2)"
echo "  aws secretsmanager get-secret-value \\"
echo "    --secret-id lab/db/credentials \\"
echo "    --region eu-west-1 \\"
echo "    --query 'SecretString' --output text"
echo ""
echo "  # Leer parámetro SSM SecureString"
echo "  aws ssm get-parameter \\"
echo "    --name /lab/config/db-host \\"
echo "    --with-decryption \\"
echo "    --region eu-west-1 \\"
echo "    --query 'Parameter.Value' --output text"
echo ""
echo "  # Intentar listar TODOS los secretos (DEBE FALLAR — policy restringe a lab/)"
echo "  aws secretsmanager list-secrets --region eu-west-1"
echo ""
echo "  # SSM Run Command para ejecutar sin sesión interactiva"
echo "  aws ssm send-command \\"
echo "    --instance-ids $INSTANCE_ID \\"
echo "    --document-name 'AWS-RunShellScript' \\"
echo "    --parameters 'commands=[\"aws secretsmanager get-secret-value --secret-id lab/db/credentials --region eu-west-1 --query SecretString --output text\"]' \\"
echo "    --region eu-west-1"

# -----------------------------------------------------------------------------
# Resumen
# -----------------------------------------------------------------------------
echo ""
echo "======================================================"
echo " Fase 6 — COMPLETADA"
echo "======================================================"
echo ""
echo "  KMS_APP_KEY_ARN  : $KMS_APP_KEY_ARN"
echo "  SECRET_ARN       : $SECRET_ARN"
echo "  SSM_PARAM_DB_HOST: $SSM_PARAM_DB_HOST (SecureString)"
echo "  SSM_PARAM_ENV    : $SSM_PARAM_ENV (String)"
echo "  IAM_ROLE         : $IAM_ROLE_NAME (kms:ViaService restringido)"
echo "  SG_ID            : $SG_ID (sin SSH, solo egress HTTPS 443)"
echo "  INSTANCE_ID      : $INSTANCE_ID (IMDSv2 required, SSM Session Manager)"
echo ""
log_warn "Acuérdate de parar o terminar la instancia cuando acabes el lab:"
echo "  aws ec2 stop-instances --instance-ids $INSTANCE_ID --region eu-west-1"
echo ""
log_ok "Lab completo. Para limpiar todos los recursos: bash ./cli/99-cleanup.sh"
