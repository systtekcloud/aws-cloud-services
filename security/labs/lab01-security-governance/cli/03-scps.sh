#!/usr/bin/env bash
# =============================================================================
# 03-scps.sh — Crear y aplicar Service Control Policies (SCPs)
# Lab: Security & Governance (lab01) — Fase 3
#
# USO: bash ./cli/03-scps.sh
# PREREQUISITO: Fase 1 completada, Organizations con feature-set ALL
# =============================================================================

source "$(dirname "$0")/00-env.sh"

echo "======================================================"
echo " Fase 3 — Service Control Policies (SCPs)"
echo "======================================================"

# Verificar que SCPs están habilitados (feature-set ALL)
log_info "Verificando que SCPs están habilitados..."
SCP_ENABLED=$(aws organizations describe-organization \
  --query 'Organization.AvailablePolicyTypes[?Type==`SERVICE_CONTROL_POLICY`].Status' \
  --output text 2>/dev/null)

if [[ "$SCP_ENABLED" != "ENABLED" ]]; then
  log_info "Habilitando SERVICE_CONTROL_POLICY en la organización..."
  aws organizations enable-policy-type \
    --root-id "$ROOT_ID" \
    --policy-type SERVICE_CONTROL_POLICY
  log_ok "SCPs habilitados"
else
  log_ok "SCPs ya están habilitados"
fi

# -----------------------------------------------------------------------------
# Función genérica para crear/actualizar SCP
# -----------------------------------------------------------------------------
create_scp() {
  local name="$1"
  local description="$2"
  local policy_content="$3"
  local var_name="$4"

  # Verificar si ya existe
  existing_id=$(aws organizations list-policies \
    --filter SERVICE_CONTROL_POLICY \
    --query "Policies[?Name=='${name}'].Id" \
    --output text 2>/dev/null)

  if [[ -n "$existing_id" && "$existing_id" != "None" ]]; then
    log_ok "SCP '$name' ya existe: $existing_id"
    eval "export ${var_name}='${existing_id}'"
    save_state "$var_name" "$existing_id"
    return 0
  fi

  log_info "Creando SCP '$name'..."
  policy_id=$(aws organizations create-policy \
    --type SERVICE_CONTROL_POLICY \
    --name "$name" \
    --description "$description" \
    --content "$policy_content" \
    --query 'Policy.PolicySummary.Id' \
    --output text)

  log_ok "SCP '$name' creada: $policy_id"
  eval "export ${var_name}='${policy_id}'"
  save_state "$var_name" "$policy_id"
}

# Adjuntar SCP a un target (OU o cuenta)
attach_scp() {
  local policy_id="$1"
  local target_id="$2"
  local description="$3"

  aws organizations attach-policy \
    --policy-id "$policy_id" \
    --target-id "$target_id" 2>/dev/null && \
    log_ok "  Adjuntada $description" || \
    log_warn "  $description — ya adjuntada"
}

# -----------------------------------------------------------------------------
# SCP-001: DenyDisableCloudTrail
# Objetivo: Root (todas las cuentas)
# -----------------------------------------------------------------------------
log_info "3.1 SCP-001: DenyDisableCloudTrail"

SCP_TRAIL_POLICY=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyDisableCloudTrail",
      "Effect": "Deny",
      "Action": [
        "cloudtrail:DeleteTrail",
        "cloudtrail:StopLogging",
        "cloudtrail:UpdateTrail",
        "cloudtrail:PutEventSelectors",
        "cloudtrail:RemoveTags"
      ],
      "Resource": "*"
    }
  ]
}
EOF
)

create_scp \
  "SCP-001-DenyDisableCloudTrail" \
  "Impide desactivar o modificar CloudTrail en toda la organización" \
  "$SCP_TRAIL_POLICY" \
  "SCP_TRAIL_ID"

attach_scp "$SCP_TRAIL_ID" "$ROOT_ID" "SCP-001 → Root"

# -----------------------------------------------------------------------------
# SCP-002: DenyRegionsExceptApproved
# Objetivo: OU Workloads (no en Management para servicios globales)
# Regiones aprobadas: eu-west-1, us-east-1 (us-east-1 para servicios globales)
# -----------------------------------------------------------------------------
log_info "3.2 SCP-002: DenyRegionsExceptApproved"

SCP_REGIONS_POLICY=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyRegionsExceptApproved",
      "Effect": "Deny",
      "NotAction": [
        "a4b:*", "acm:*", "aws-marketplace-management:*",
        "aws-marketplace:*", "aws-portal:*", "budgets:*",
        "ce:*", "chime:*", "cloudfront:*", "config:*",
        "cur:*", "directconnect:*", "ec2:DescribeRegions",
        "ec2:DescribeTransitGateways", "ec2:DescribeVpnGateways",
        "fms:*", "globalaccelerator:*", "health:*",
        "iam:*", "importexport:*", "kms:*", "mobileanalytics:*",
        "networkmanager:*", "organizations:*", "pricing:*",
        "route53:*", "route53domains:*", "s3:GetAccountPublicAccessBlock",
        "shield:*", "sts:*", "support:*", "trustedadvisor:*",
        "waf-regional:*", "waf:*", "wafv2:*", "wellarchitected:*"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:RequestedRegion": ["eu-west-1", "us-east-1"]
        },
        "StringNotLike": {
          "aws:PrincipalARN": [
            "arn:aws:iam::*:role/OrganizationAccountAccessRole",
            "arn:aws:iam::*:role/AWSControlTowerExecution",
            "arn:aws:iam::*:role/aws-reserved/sso.amazonaws.com/*"
          ]
        }
      }
    }
  ]
}
EOF
)

create_scp \
  "SCP-002-DenyRegionsExceptApproved" \
  "Restringe despliegue a eu-west-1 y us-east-1 — Workloads OU" \
  "$SCP_REGIONS_POLICY" \
  "SCP_REGIONS_ID"

# Adjuntar a OU Workloads (no a Root, para no bloquear Management)
if [[ -n "$OU_WORKLOADS" ]]; then
  attach_scp "$SCP_REGIONS_ID" "$OU_WORKLOADS" "SCP-002 → OU Workloads"
else
  log_warn "OU_WORKLOADS no definido, adjuntar manualmente"
fi

# -----------------------------------------------------------------------------
# SCP-003: DenyS3PublicAccess
# Objetivo: Root (todas las cuentas)
# -----------------------------------------------------------------------------
log_info "3.3 SCP-003: DenyS3PublicAccess"

SCP_S3_POLICY=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyS3PublicAccessBlock",
      "Effect": "Deny",
      "Action": "s3:PutBucketPublicAccessBlock",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "s3:PublicAccessBlockConfiguration/RestrictPublicBuckets": "false"
        }
      }
    },
    {
      "Sid": "DenyS3PublicACL",
      "Effect": "Deny",
      "Action": [
        "s3:PutBucketAcl",
        "s3:PutObjectAcl"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "s3:x-amz-acl": [
            "public-read",
            "public-read-write",
            "authenticated-read"
          ]
        }
      }
    },
    {
      "Sid": "DenyS3PublicPolicy",
      "Effect": "Deny",
      "Action": "s3:PutBucketPolicy",
      "Resource": "*",
      "Condition": {
        "Bool": {
          "s3:PublicPolicy": "true"
        }
      }
    }
  ]
}
EOF
)

create_scp \
  "SCP-003-DenyS3PublicAccess" \
  "Impide configurar buckets S3 como públicos en toda la organización" \
  "$SCP_S3_POLICY" \
  "SCP_S3_ID"

attach_scp "$SCP_S3_ID" "$ROOT_ID" "SCP-003 → Root"

# -----------------------------------------------------------------------------
# 3.4 SCP-004: DenyLeaveOrganization (bonus — buena práctica)
# -----------------------------------------------------------------------------
log_info "3.4 SCP-004: DenyLeaveOrganization (bonus)"

SCP_LEAVE_POLICY=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyLeaveOrganization",
      "Effect": "Deny",
      "Action": "organizations:LeaveOrganization",
      "Resource": "*"
    }
  ]
}
EOF
)

SCP_LEAVE_ID=""
create_scp \
  "SCP-004-DenyLeaveOrganization" \
  "Impide que las cuentas miembro salgan de la organización" \
  "$SCP_LEAVE_POLICY" \
  "SCP_LEAVE_ID"

attach_scp "$SCP_LEAVE_ID" "$ROOT_ID" "SCP-004 → Root"

# -----------------------------------------------------------------------------
# 3.5 Validar SCPs — Tests de verificación
# -----------------------------------------------------------------------------
echo ""
log_info "3.5 Validando SCPs aplicadas..."

echo ""
log_info "SCPs adjuntadas al Root:"
aws organizations list-policies-for-target \
  --target-id "$ROOT_ID" \
  --filter SERVICE_CONTROL_POLICY \
  --query 'Policies[*].[Name,Id]' \
  --output table

if [[ -n "$OU_WORKLOADS" ]]; then
  echo ""
  log_info "SCPs adjuntadas a OU Workloads:"
  aws organizations list-policies-for-target \
    --target-id "$OU_WORKLOADS" \
    --filter SERVICE_CONTROL_POLICY \
    --query 'Policies[*].[Name,Id]' \
    --output table
fi

echo ""
log_info "Tests de validación SCP (ejecutar manualmente para verificar bloqueo):"
echo ""
echo "  # Test SCP-001: Debe fallar con 'explicit deny in a service control policy'"
echo "  aws cloudtrail stop-logging --name lab-org-trail"
echo ""
echo "  # Test SCP-003: Debe fallar"
echo "  TEST_BUCKET=\"test-scp-\$(date +%s)\""
echo "  aws s3api create-bucket --bucket \"\$TEST_BUCKET\" --region eu-west-1 --create-bucket-configuration LocationConstraint=eu-west-1"
echo "  aws s3api put-bucket-acl --bucket \"\$TEST_BUCKET\" --acl public-read"
echo "  aws s3api delete-bucket --bucket \"\$TEST_BUCKET\" --region eu-west-1"
echo ""
echo "  # Test SCP-002 (desde cuenta en OU Workloads): Debe fallar"
echo "  aws ec2 describe-instances --region ap-southeast-1"

# -----------------------------------------------------------------------------
# Resumen
# -----------------------------------------------------------------------------
echo ""
echo "======================================================"
echo " Fase 3 — COMPLETADA"
echo "======================================================"
echo ""
echo "SCPs creadas:"
echo "  SCP_TRAIL_ID   : $SCP_TRAIL_ID   (DenyDisableCloudTrail → Root)"
echo "  SCP_REGIONS_ID : $SCP_REGIONS_ID (DenyRegionsExceptApproved → Workloads)"
echo "  SCP_S3_ID      : $SCP_S3_ID      (DenyS3PublicAccess → Root)"
echo "  SCP_LEAVE_ID   : $SCP_LEAVE_ID   (DenyLeaveOrganization → Root)"
echo ""
log_warn "Nota: Las SCPs NO afectan a la Management Account por diseño de Organizations"
log_warn "Nota: Roles en StringNotLike están exentos de SCP-002 (OrganizationAccountAccessRole, SSO)"
echo ""
log_ok "Estado guardado en: $STATE_FILE"
log_info "Siguiente paso: bash ./cli/04-logging-central.sh"
