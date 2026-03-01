#!/usr/bin/env bash
# =============================================================================
# Lab v3 — Fase A1 y A2: Secrets Manager e IAM
# ShopAPI — ECS Fargate
#
# Que hace este script:
#   1. Crea el secret shopapi/prod/db en Secrets Manager
#   2. Verifica el secret
#   3. Crea el Task Role (shopapi-task-role) con trust policy para ECS Tasks
#   4. Añade política inline de DynamoDB al Task Role
#   5. Añade permiso secretsmanager:GetSecretValue al Execution Role
# =============================================================================
set -euo pipefail

# ─── Variables ───────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-eu-west-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
SECRET_NAME="shopapi/prod/db"
TASK_ROLE_NAME="shopapi-task-role"
EXECUTION_ROLE_NAME="shopapi-execution-role"
DYNAMODB_TABLE="shopapi-products"

echo "========================================================"
echo "  Lab v3 — Secrets Manager e IAM"
echo "  Cuenta: ${ACCOUNT_ID}"
echo "  Region: ${AWS_REGION}"
echo "========================================================"
echo ""

# =============================================================================
# A1 — SECRETS MANAGER
# =============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "FASE A1: Creando secret en Secrets Manager"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Verificar si el secret ya existe
if aws secretsmanager describe-secret \
    --secret-id "${SECRET_NAME}" \
    --region "${AWS_REGION}" \
    --output text > /dev/null 2>&1; then
  echo "[INFO] El secret '${SECRET_NAME}' ya existe. Actualizando el valor..."
  aws secretsmanager put-secret-value \
    --secret-id "${SECRET_NAME}" \
    --secret-string '{
      "host": "db.shopapi.internal",
      "port": 5432,
      "username": "shopapi_app",
      "password": "changeme_en_prod"
    }' \
    --region "${AWS_REGION}"
  echo "[OK] Secret actualizado."
else
  echo "[INFO] Creando secret '${SECRET_NAME}'..."
  aws secretsmanager create-secret \
    --name "${SECRET_NAME}" \
    --description "Credenciales de base de datos para ShopAPI en produccion" \
    --secret-string '{
      "host": "db.shopapi.internal",
      "port": 5432,
      "username": "shopapi_app",
      "password": "changeme_en_prod"
    }' \
    --region "${AWS_REGION}"
  echo "[OK] Secret creado."
fi

# Obtener el ARN completo del secret (incluye sufijo aleatorio de 6 caracteres)
SECRET_ARN=$(aws secretsmanager describe-secret \
  --secret-id "${SECRET_NAME}" \
  --region "${AWS_REGION}" \
  --query 'ARN' \
  --output text)

echo ""
echo "[INFO] ARN del secret: ${SECRET_ARN}"

# ─── Verificar el secret ────────────────────────────────────────────────────
echo ""
echo "[INFO] Verificando el contenido del secret..."
echo "Valor del secret (solo en lab — no hacer esto en produccion):"
aws secretsmanager get-secret-value \
  --secret-id "${SECRET_NAME}" \
  --region "${AWS_REGION}" \
  --query 'SecretString' \
  --output text | python3 -m json.tool

echo ""
echo "[INFO] Metadatos del secret:"
aws secretsmanager describe-secret \
  --secret-id "${SECRET_NAME}" \
  --region "${AWS_REGION}" \
  --query '{Nombre:Name,ARN:ARN,FechaCreacion:CreatedDate,RotacionHabilitada:RotationEnabled}' \
  --output table

# =============================================================================
# A2 — IAM TASK ROLE
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "FASE A2: Creando Task Role (shopapi-task-role)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── Trust Policy para ECS Tasks ─────────────────────────────────────────────
# Solo los ECS Tasks pueden asumir este rol (no EC2, no Lambda, no usuarios)
TRUST_POLICY=$(cat << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "ArnLike": {
          "aws:SourceArn": "arn:aws:ecs:eu-west-1:*:*"
        },
        "StringEquals": {
          "aws:SourceAccount": "*"
        }
      }
    }
  ]
}
EOF
)

# Crear el Task Role (o verificar que ya existe)
if aws iam get-role --role-name "${TASK_ROLE_NAME}" > /dev/null 2>&1; then
  echo "[INFO] El rol '${TASK_ROLE_NAME}' ya existe. Omitiendo creacion."
else
  echo "[INFO] Creando rol '${TASK_ROLE_NAME}'..."
  aws iam create-role \
    --role-name "${TASK_ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_POLICY}" \
    --description "Task Role para ShopAPI: permisos que usa la aplicacion en ejecucion (no el agente de ECS)"
  echo "[OK] Rol creado."
fi

TASK_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${TASK_ROLE_NAME}"
echo "[INFO] Task Role ARN: ${TASK_ROLE_ARN}"

# ─── Policy Inline: DynamoDB para shopapi-products ───────────────────────────
echo ""
echo "[INFO] Añadiendo política inline para DynamoDB (tabla: ${DYNAMODB_TABLE})..."

DYNAMODB_POLICY=$(cat << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LeerProductos",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:Query",
        "dynamodb:Scan",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem"
      ],
      "Resource": [
        "arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${DYNAMODB_TABLE}",
        "arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${DYNAMODB_TABLE}/index/*"
      ]
    }
  ]
}
EOF
)

aws iam put-role-policy \
  --role-name "${TASK_ROLE_NAME}" \
  --policy-name "shopapi-dynamodb-products" \
  --policy-document "${DYNAMODB_POLICY}"

echo "[OK] Política DynamoDB añadida al Task Role."

# ─── Verificar el Task Role ───────────────────────────────────────────────────
echo ""
echo "[INFO] Políticas del Task Role:"
aws iam list-role-policies \
  --role-name "${TASK_ROLE_NAME}" \
  --query 'PolicyNames' \
  --output table

# =============================================================================
# A2 — ACTUALIZAR EXECUTION ROLE (añadir Secrets Manager)
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "FASE A2: Actualizando Execution Role con acceso a Secrets Manager"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Verificar que el Execution Role existe
if ! aws iam get-role --role-name "${EXECUTION_ROLE_NAME}" > /dev/null 2>&1; then
  echo "[ERROR] El Execution Role '${EXECUTION_ROLE_NAME}' no existe."
  echo "        Asegurate de haber completado el Lab v1/v2 antes de ejecutar este script."
  exit 1
fi

EXECUTION_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${EXECUTION_ROLE_NAME}"
echo "[INFO] Execution Role ARN: ${EXECUTION_ROLE_ARN}"

# Política para leer el secret específico (principio de mínimo privilegio)
# IMPORTANTE: usamos el ARN exacto del secret, no un wildcard
SECRETS_POLICY=$(cat << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LeerSecretShopAPI",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "${SECRET_ARN}"
    }
  ]
}
EOF
)

# Nota: Si el secret usa una CMK (Customer Managed Key) en lugar de la clave
# gestionada por AWS, también necesitas añadir:
#   "kms:Decrypt" en el KMS key ARN correspondiente

aws iam put-role-policy \
  --role-name "${EXECUTION_ROLE_NAME}" \
  --policy-name "shopapi-secrets-access" \
  --policy-document "${SECRETS_POLICY}"

echo "[OK] Permiso secretsmanager:GetSecretValue añadido al Execution Role."

# ─── Verificar Execution Role actualizado ─────────────────────────────────────
echo ""
echo "[INFO] Políticas del Execution Role:"
aws iam list-role-policies \
  --role-name "${EXECUTION_ROLE_NAME}" \
  --query 'PolicyNames' \
  --output table

echo ""
echo "[INFO] Políticas gestionadas adjuntas al Execution Role:"
aws iam list-attached-role-policies \
  --role-name "${EXECUTION_ROLE_NAME}" \
  --query 'AttachedPolicies[*].{Nombre:PolicyName,ARN:PolicyArn}' \
  --output table

# =============================================================================
# RESUMEN
# =============================================================================
echo ""
echo "========================================================"
echo "  RESUMEN — Recursos creados/actualizados"
echo "========================================================"
echo ""
echo "  Secret Secrets Manager:"
echo "    Nombre : ${SECRET_NAME}"
echo "    ARN    : ${SECRET_ARN}"
echo ""
echo "  Task Role (nuevas permisos para la APP):"
echo "    Nombre : ${TASK_ROLE_NAME}"
echo "    ARN    : ${TASK_ROLE_ARN}"
echo "    Política: shopapi-dynamodb-products (DynamoDB)"
echo ""
echo "  Execution Role (agente ECS — arranque del contenedor):"
echo "    Nombre : ${EXECUTION_ROLE_NAME}"
echo "    ARN    : ${EXECUTION_ROLE_ARN}"
echo "    Política añadida: shopapi-secrets-access (Secrets Manager)"
echo ""
echo "  Próximo paso: ejecutar 02-observabilidad.sh"
echo "========================================================"

# Exportar ARNs para el siguiente script
echo ""
echo "# Copia estas variables para los siguientes scripts:"
echo "export SECRET_ARN='${SECRET_ARN}'"
echo "export TASK_ROLE_ARN='${TASK_ROLE_ARN}'"
echo "export EXECUTION_ROLE_ARN='${EXECUTION_ROLE_ARN}'"
echo "export ACCOUNT_ID='${ACCOUNT_ID}'"
