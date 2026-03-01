#!/usr/bin/env bash
# =============================================================================
# v1 — Paso 1: Prerrequisitos (Budget, Key Pair, IAM Role)
# =============================================================================
set -euo pipefail

: "${REGION:=eu-west-1}"
: "${PROJECT:=ec2-lab}"
: "${ACCOUNT_ID:=$(aws sts get-caller-identity --query Account --output text)}"
: "${ALERT_EMAIL:?Exporta ALERT_EMAIL=tu@email.com}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

# -----------------------------------------------------------------------------
info "1/4 — Creando Budget alarm (25 USD, alerta al 80%)..."
# -----------------------------------------------------------------------------
aws budgets create-budget \
  --account-id "$ACCOUNT_ID" \
  --budget "{
    \"BudgetName\": \"${PROJECT}-budget\",
    \"BudgetLimit\": {\"Amount\": \"25\", \"Unit\": \"USD\"},
    \"TimeUnit\": \"MONTHLY\",
    \"BudgetType\": \"COST\"
  }" \
  --notifications-with-subscribers "[{
    \"Notification\": {
      \"NotificationType\": \"ACTUAL\",
      \"ComparisonOperator\": \"GREATER_THAN\",
      \"Threshold\": 80,
      \"ThresholdType\": \"PERCENTAGE\"
    },
    \"Subscribers\": [{
      \"SubscriptionType\": \"EMAIL\",
      \"Address\": \"${ALERT_EMAIL}\"
    }]
  }]" 2>/dev/null && success "Budget creado." || warn "Budget ya existe."

# -----------------------------------------------------------------------------
info "2/4 — Creando Key Pair (solo para emergencias — usaremos SSM)..."
# -----------------------------------------------------------------------------
if ! aws ec2 describe-key-pairs --key-names "${PROJECT}-key" --region "$REGION" &>/dev/null; then
  aws ec2 create-key-pair \
    --key-name "${PROJECT}-key" \
    --query 'KeyMaterial' \
    --output text \
    --region "$REGION" > ~/.ssh/${PROJECT}-key.pem
  chmod 400 ~/.ssh/${PROJECT}-key.pem
  success "Key pair creado: ~/.ssh/${PROJECT}-key.pem"
else
  warn "Key pair ya existe."
fi

# -----------------------------------------------------------------------------
info "3/4 — Creando IAM Role para EC2 (SSM + CloudWatch + S3 + Secrets)..."
# -----------------------------------------------------------------------------
# Trust policy
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

if ! aws iam get-role --role-name "${PROJECT}-instance-role" &>/dev/null; then
  aws iam create-role \
    --role-name "${PROJECT}-instance-role" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --tags "Key=Project,Value=${PROJECT}"
  success "IAM Role creado."
else
  warn "IAM Role ya existe."
fi

# Adjuntar políticas AWS managed
for POLICY_ARN in \
  "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" \
  "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"; do
  aws iam attach-role-policy \
    --role-name "${PROJECT}-instance-role" \
    --policy-arn "$POLICY_ARN" 2>/dev/null || true
done

# Política custom S3 (least privilege)
aws iam put-role-policy \
  --role-name "${PROJECT}-instance-role" \
  --policy-name "${PROJECT}-s3-assets" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [\"s3:GetObject\", \"s3:ListBucket\"],
      \"Resource\": [
        \"arn:aws:s3:::${PROJECT}-assets-${ACCOUNT_ID}\",
        \"arn:aws:s3:::${PROJECT}-assets-${ACCOUNT_ID}/*\"
      ]
    }]
  }"

# Política custom Secrets Manager (solo secretos del lab)
aws iam put-role-policy \
  --role-name "${PROJECT}-instance-role" \
  --policy-name "${PROJECT}-secrets" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [\"secretsmanager:GetSecretValue\"],
      \"Resource\": \"arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret:${PROJECT}/*\"
    }]
  }"

# Instance Profile
if ! aws iam get-instance-profile --instance-profile-name "${PROJECT}-instance-profile" &>/dev/null; then
  aws iam create-instance-profile \
    --instance-profile-name "${PROJECT}-instance-profile" \
    --tags "Key=Project,Value=${PROJECT}"
  aws iam add-role-to-instance-profile \
    --instance-profile-name "${PROJECT}-instance-profile" \
    --role-name "${PROJECT}-instance-role"
  success "Instance Profile creado."
else
  warn "Instance Profile ya existe."
fi

# -----------------------------------------------------------------------------
info "4/4 — Creando S3 bucket para assets y logs..."
# -----------------------------------------------------------------------------
BUCKET="${PROJECT}-assets-${ACCOUNT_ID}"
if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  success "S3 bucket creado: s3://$BUCKET"
else
  warn "S3 bucket ya existe."
fi

echo ""
success "=== Prerrequisitos completados ==="
echo "  IAM Instance Profile : ${PROJECT}-instance-profile"
echo "  Key Pair             : ~/.ssh/${PROJECT}-key.pem"
echo "  S3 Bucket            : s3://$BUCKET"
