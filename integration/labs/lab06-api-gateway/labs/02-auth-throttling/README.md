# Lab 06-B: Auth y Throttling

**Objetivo:** Configurar Lambda Authorizer, API Keys con Usage Plans, throttling por método, y demostrar el 429 Too Many Requests.

**Tiempo estimado:** 50 min  
**Coste estimado:** $0

---

## Parte A: Lambda Authorizer (Token-based)

### Concepto

```
Cliente → request con Authorization: Bearer <token>
                │
                ▼
        API Gateway
                │
                ▼ (si no está cacheada la policy)
        Lambda Authorizer
          valida el token
          devuelve IAM policy (Allow/Deny)
                │
                ▼ (policy cacheada 300s por token)
        Backend (si Allow)
```

### Paso 1: Función Lambda Authorizer

```bash
ROLE_ARN=$(aws iam get-role --role-name lab01-lambda-basic-role 2>/dev/null \
  --query 'Role.Arn' --output text || \
  aws iam get-role --role-name lab05-sfn-lambda-role \
  --query 'Role.Arn' --output text)

cat > /tmp/lab06-authorizer.py << 'EOF'
import json

# Tokens válidos (en producción: validar JWT con clave pública)
VALID_TOKENS = {
    "token-admin":     {"principalId": "user-admin", "role": "admin"},
    "token-readonly":  {"principalId": "user-reader", "role": "reader"},
}

def handler(event, context):
    token = event.get('authorizationToken', '')
    method_arn = event.get('methodArn', '')
    
    # Verificar token
    if token in VALID_TOKENS:
        user_info = VALID_TOKENS[token]
        effect = 'Allow'
        principal = user_info['principalId']
        context_data = {'role': user_info['role']}
    else:
        effect = 'Deny'
        principal = 'unauthorized'
        context_data = {}
    
    # Construir IAM policy
    policy = {
        'principalId': principal,
        'policyDocument': {
            'Version': '2012-10-17',
            'Statement': [{
                'Action': 'execute-api:Invoke',
                'Effect': effect,
                'Resource': method_arn
            }]
        },
        'context': context_data  # Disponible en Lambda backend como $context.authorizer.*
    }
    
    print(f"Authorizer: {effect} para token={token[:20]}...")
    return policy
EOF

cd /tmp && zip lab06-authorizer.zip lab06-authorizer.py

aws lambda create-function \
  --function-name lab06-authorizer \
  --runtime python3.12 \
  --handler lab06-authorizer.handler \
  --role "$ROLE_ARN" \
  --zip-file fileb:///tmp/lab06-authorizer.zip \
  --timeout 5 \
  --region eu-west-1 2>/dev/null || \
aws lambda update-function-code \
  --function-name lab06-authorizer \
  --zip-file fileb:///tmp/lab06-authorizer.zip \
  --region eu-west-1

AUTH_ARN=$(aws lambda get-function \
  --function-name lab06-authorizer \
  --region eu-west-1 \
  --query 'Configuration.FunctionArn' --output text)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

### Paso 2: Configurar el authorizer en la REST API

```bash
# Usar la REST API del lab anterior o crear una nueva
REST_ID=$(aws apigateway get-rest-apis \
  --region eu-west-1 \
  --query "items[?name=='lab06-rest-api'].id" --output text)

# Si no existe, crear una nueva
if [ -z "$REST_ID" ]; then
  REST_ID=$(aws apigateway create-rest-api \
    --name lab06-rest-api \
    --region eu-west-1 \
    --query 'id' --output text)
fi

# Dar permiso a API GW para invocar el authorizer
aws lambda add-permission \
  --function-name lab06-authorizer \
  --statement-id apigw-authorizer \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:eu-west-1:$ACCOUNT_ID:$REST_ID/authorizers/*" \
  --region eu-west-1 2>/dev/null || true

# Crear el authorizer
AUTHORIZER_ID=$(aws apigateway create-authorizer \
  --rest-api-id "$REST_ID" \
  --name lab06-token-authorizer \
  --type TOKEN \
  --authorizer-uri "arn:aws:apigateway:eu-west-1:lambda:path/2015-03-31/functions/$AUTH_ARN/invocations" \
  --identity-source "method.request.header.Authorization" \
  --authorizer-result-ttl-in-seconds 300 \
  --region eu-west-1 \
  --query 'id' --output text)

echo "Authorizer ID: $AUTHORIZER_ID"
```

### Paso 3: Probar el authorizer

```bash
REST_URL="https://$REST_ID.execute-api.eu-west-1.amazonaws.com/dev/items"

# Sin token → 401
echo "=== Sin token ==="
curl -s -o /dev/null -w "%{http_code}" "$REST_URL"

# Con token inválido → 403
echo ""
echo "=== Token inválido ==="
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: token-falso" "$REST_URL"

# Con token válido → 200
echo ""
echo "=== Token válido (admin) ==="
curl -s -H "Authorization: token-admin" "$REST_URL" | python3 -m json.tool

# Con token de solo lectura → 200
echo ""
echo "=== Token válido (readonly) ==="
curl -s -H "Authorization: token-readonly" "$REST_URL"
```

---

## Parte B: API Keys y Usage Plans

### Paso 4: Crear API Key y Usage Plan

```bash
# 4.1 Crear API Key
API_KEY_ID=$(aws apigateway create-api-key \
  --name lab06-key-free-tier \
  --enabled \
  --region eu-west-1 \
  --query 'id' --output text)

API_KEY_VALUE=$(aws apigateway get-api-key \
  --api-key "$API_KEY_ID" \
  --include-value \
  --region eu-west-1 \
  --query 'value' --output text)

echo "API Key: $API_KEY_VALUE"

# 4.2 Crear Usage Plan con throttling y quota
PLAN_ID=$(aws apigateway create-usage-plan \
  --name lab06-free-tier \
  --description "Plan gratuito: 100 req/día, 10 req/s" \
  --throttle burstLimit=20,rateLimit=10 \
  --quota limit=100,period=DAY \
  --api-stages "apiId=$REST_ID,stage=dev" \
  --region eu-west-1 \
  --query 'id' --output text)

# 4.3 Asociar la API Key al Usage Plan
aws apigateway create-usage-plan-key \
  --usage-plan-id "$PLAN_ID" \
  --key-id "$API_KEY_ID" \
  --key-type API_KEY \
  --region eu-west-1

echo "Usage Plan ID: $PLAN_ID"
echo "API Key Value: $API_KEY_VALUE"
```

### Paso 5: Demostrar throttling 429

```bash
# 5.1 Enviar múltiples requests rápidos para superar el rate limit (10 req/s)
echo "=== Disparando 20 requests rápidos para provocar throttling ==="
for i in $(seq 1 20); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "x-api-key: $API_KEY_VALUE" "$REST_URL")
  echo "Request $i: HTTP $CODE"
done

# Verás HTTP 429 Too Many Requests en algunos requests
```

---

## Parte C: Cognito Authorizer (concepto)

```bash
# En HTTP API, JWT authorizer se configura así:
aws apigatewayv2 create-authorizer \
  --api-id "$HTTP_ID" \
  --authorizer-type JWT \
  --identity-source '$request.header.Authorization' \
  --name CognitoAuthorizer \
  --jwt-configuration \
    "Audience=[\"tu-app-client-id\"],Issuer=https://cognito-idp.eu-west-1.amazonaws.com/eu-west-1_XXXXX" \
  --region eu-west-1

# API Gateway valida automáticamente:
#   1. Firma del JWT (usando JWKS del issuer)
#   2. Expiración (exp claim)
#   3. Audience (aud claim)
# Sin necesidad de Lambda authorizer
```

---

## Limpieza

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REST_ID=$(aws apigateway get-rest-apis --region eu-west-1 \
  --query "items[?name=='lab06-rest-api'].id" --output text)
HTTP_ID=$(aws apigatewayv2 get-apis --region eu-west-1 \
  --query "Items[?Name=='lab06-http-api'].ApiId" --output text)

[ -n "$REST_ID" ] && aws apigateway delete-rest-api --rest-api-id "$REST_ID" --region eu-west-1
[ -n "$HTTP_ID" ] && aws apigatewayv2 delete-api --api-id "$HTTP_ID" --region eu-west-1

for fn in lab06-apigw-handler lab06-authorizer; do
  aws lambda delete-function --function-name "$fn" --region eu-west-1 2>/dev/null || true
done
```
