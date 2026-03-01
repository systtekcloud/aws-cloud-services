# Troubleshooting #2 — Fallo en inyección de Secrets Manager

## Síntoma

El task pasa a estado `STOPPED` casi inmediatamente después de `PROVISIONING` y nunca llega a `RUNNING`.

```bash
# Verificar estado del task
aws ecs describe-tasks \
  --cluster shopapi-cluster \
  --tasks $(aws ecs list-tasks --cluster shopapi-cluster --query 'taskArns[0]' --output text) \
  --query 'tasks[0].{estado:lastStatus,stopCode:stopCode,razon:stoppedReason}'
```

**Resultado típico**:
```json
{
  "estado": "STOPPED",
  "stopCode": "TaskFailedToStart",
  "razon": "ResourceInitializationError: unable to pull secrets or registry auth: execution resource retrieval failed: unable to retrieve secret from asm: service call has been retried 5 time(s)..."
}
```

---

## Causa raíz

El **Execution Role** no tiene permiso para llamar a `secretsmanager:GetSecretValue` para el ARN del secret que referencia la Task Definition.

Recuerda: la inyección de secrets ocurre en la fase `PROVISIONING` **antes de que el container arranque**. Si falla, el task nunca llega a `RUNNING`.

```
PROVISIONING
   │
   ├── ECS llama a secretsmanager:GetSecretValue (usando Execution Role)
   │   └── ❌ AccessDeniedException → task STOPPED (TaskFailedToStart)
   │
   └── Si OK → descarga imagen → arranca container → RUNNING
```

---

## Diagnóstico

### Paso 1: Confirmar con CloudTrail

```bash
# Buscar el evento AccessDeniedException en CloudTrail
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=GetSecretValue \
  --start-time $(date -d '1 hour ago' --utc +%Y-%m-%dT%H:%M:%SZ) \
  --query 'Events[?contains(CloudTrailEvent, `AccessDenied`)].{time:EventTime,user:Username,error:CloudTrailEvent}' \
  --output table
```

### Paso 2: Ver la policy actual del Execution Role

```bash
EXEC_ROLE_NAME="shopapi-execution-role"

# Ver las policies adjuntas
aws iam list-attached-role-policies --role-name $EXEC_ROLE_NAME

# Ver las policies inline
aws iam list-role-policies --role-name $EXEC_ROLE_NAME

# Ver el contenido de la policy inline
aws iam get-role-policy \
  --role-name $EXEC_ROLE_NAME \
  --policy-name SecretsManagerPolicy
```

### Paso 3: Verificar qué ARN referencia la Task Definition

```bash
aws ecs describe-task-definition \
  --task-definition shopapi-api \
  --query 'taskDefinition.containerDefinitions[0].secrets'
```

Compara el ARN del `valueFrom` con lo que permite la policy del Execution Role.

---

## Solución

### Opción A: Añadir permiso al Execution Role (recomendado)

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
SECRET_ARN="arn:aws:secretsmanager:eu-west-1:${AWS_ACCOUNT_ID}:secret:shopapi/prod/db-*"

# Policy document mínima necesaria
cat > /tmp/secrets-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowGetShopApiSecrets",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "${SECRET_ARN}"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name shopapi-execution-role \
  --policy-name SecretsManagerPolicy \
  --policy-document file:///tmp/secrets-policy.json

echo "✅ Policy añadida. Lanzar un nuevo task para verificar."
```

> **Nota**: el ARN tiene `-*` al final porque Secrets Manager añade un sufijo de 6 caracteres aleatorios al nombre del secret.

### Opción B: Si el secret usa KMS Customer Managed Key

Si el secret está cifrado con una CMK (no la key por defecto de Secrets Manager), el Execution Role también necesita `kms:Decrypt`:

```bash
KMS_KEY_ARN="arn:aws:kms:eu-west-1:${AWS_ACCOUNT_ID}:key/TU-KEY-ID"

cat > /tmp/kms-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowDecryptShopApiKey",
      "Effect": "Allow",
      "Action": "kms:Decrypt",
      "Resource": "${KMS_KEY_ARN}",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": "secretsmanager.eu-west-1.amazonaws.com"
        }
      }
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name shopapi-execution-role \
  --policy-name KMSDecryptPolicy \
  --policy-document file:///tmp/kms-policy.json
```

---

## Verificación

```bash
# Lanzar nuevo task y verificar que llega a RUNNING
NEW_TASK=$(aws ecs run-task \
  --cluster shopapi-cluster \
  --task-definition shopapi-api \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[SUBNET_ID],securityGroups=[SG_ID]}" \
  --query 'tasks[0].taskArn' \
  --output text)

# Esperar y verificar estado
sleep 30
aws ecs describe-tasks \
  --cluster shopapi-cluster \
  --tasks $NEW_TASK \
  --query 'tasks[0].{estado:lastStatus,stopCode:stopCode}'
```

---

## Conceptos clave para el examen

| Pregunta | Respuesta |
|---------|-----------|
| ¿Qué rol usa ECS para inyectar secrets? | **Execution Role** (no Task Role) |
| ¿Cuándo ocurre la inyección? | En `PROVISIONING`, antes de arrancar el container |
| ¿Qué `stopCode` indica este error? | `TaskFailedToStart` con `ResourceInitializationError` |
| ¿Necesito `kms:Decrypt` siempre? | Solo si el secret usa una CMK (no la key por defecto) |
| ¿El Task Role puede inyectar secrets? | No — el Task Role es para permisos de la app en runtime |
