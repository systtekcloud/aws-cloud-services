#!/usr/bin/env bash
# v2 — CLI 04: Secrets Manager + políticas IAM + nuevo Launch Template
# Sube las credenciales a Secrets Manager y actualiza el ASG
set -euo pipefail

source ~/.ec2-lab-env

echo "=== v2: Configurando Secrets Manager ==="

# Secret de Aurora
SECRET_DB_ARN=$(aws secretsmanager create-secret \
  --name "${PROJECT}/aurora/credentials" \
  --description "Aurora MySQL credentials para ${PROJECT}" \
  --secret-string "{\"username\":\"${DB_USER}\",\"password\":\"${DB_PASS}\",\"host\":\"${AURORA_WRITER}\",\"dbname\":\"${DB_NAME}\",\"port\":3306}" \
  --query 'ARN' --output text)

echo "Secret Aurora creado: $SECRET_DB_ARN"

# Secret de Redis auth token
SECRET_REDIS_ARN=$(aws secretsmanager create-secret \
  --name "${PROJECT}/redis/auth-token" \
  --description "Redis auth token para ${PROJECT}" \
  --secret-string "{\"auth_token\":\"${REDIS_AUTH_TOKEN}\",\"endpoint\":\"${REDIS_ENDPOINT}\"}" \
  --query 'ARN' --output text)

echo "Secret Redis creado: $SECRET_REDIS_ARN"

# Actualizar la política IAM del rol EC2 para permitir GetSecretValue
cat > /tmp/secrets-policy.json << POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": [
        "${SECRET_DB_ARN}",
        "${SECRET_REDIS_ARN}"
      ]
    }
  ]
}
POLICY

EC2_ROLE="${PROJECT}-lab-ec2-role"
aws iam put-role-policy \
  --role-name "$EC2_ROLE" \
  --policy-name "secrets-manager-access" \
  --policy-document file:///tmp/secrets-policy.json

echo "Política IAM actualizada: GetSecretValue en secrets del lab"

# Activar rotación automática (30 días) para el secret de Aurora
# Nota: requiere una Lambda de rotación — simplificado para el lab con managed rotation
aws secretsmanager rotate-secret \
  --secret-id "$SECRET_DB_ARN" \
  --rotation-rules AutomaticallyAfterDays=30 2>/dev/null || \
  echo "INFO: Rotación automática requiere Lambda — configurar en console si se necesita"

# Subir app.py actualizada con soporte DB+Cache al bucket S3
aws s3 cp "$(dirname "$0")/../../../../app/app.py" "s3://${S3_BUCKET}/app/app.py"
echo "app.py subida a S3"

# Instance Refresh para que el ASG recoja la nueva app
echo "Iniciando Instance Refresh del ASG..."
REFRESH_ID=$(aws autoscaling start-instance-refresh \
  --auto-scaling-group-name "$ASG_NAME" \
  --strategy Rolling \
  --preferences '{"MinHealthyPercentage":50,"InstanceWarmup":120}' \
  --query 'InstanceRefreshId' --output text)

echo "Instance Refresh iniciado: $REFRESH_ID"
echo "Esperar a que termine:"
echo "  aws autoscaling describe-instance-refreshes --auto-scaling-group-name $ASG_NAME"

cat >> ~/.ec2-lab-env << EOF

# v2 — Secrets Manager
export SECRET_DB_ARN="$SECRET_DB_ARN"
export SECRET_REDIS_ARN="$SECRET_REDIS_ARN"
EOF

echo "=== Secrets Manager configurado ==="
