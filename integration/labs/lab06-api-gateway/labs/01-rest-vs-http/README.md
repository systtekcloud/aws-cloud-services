# Lab 06-A: REST API vs HTTP API

**Objetivo:** Crear la misma API con Lambda backend en REST API y HTTP API. Comparar latencia, configuración y funcionalidades disponibles.

**Tiempo estimado:** 45 min  
**Coste estimado:** $0 (free tier)

---

## Paso 1: Lambda backend compartido

```bash
ROLE_ARN=$(aws iam get-role --role-name lab01-lambda-basic-role 2>/dev/null \
  --query 'Role.Arn' --output text || \
  aws iam get-role --role-name lab05-sfn-lambda-role \
  --query 'Role.Arn' --output text)

cat > /tmp/apigw-handler.py << 'EOF'
import json
import time

def handler(event, context):
    """Handler que funciona con REST API (proxy) y HTTP API (proxy)"""
    # Extraer información del request
    method = event.get('httpMethod') or event.get('requestContext', {}).get('http', {}).get('method', 'UNKNOWN')
    path   = event.get('path') or event.get('rawPath', '/')
    params = event.get('queryStringParameters') or {}
    body   = event.get('body') or '{}'
    
    response_body = {
        'message': 'Hola desde Lambda',
        'method': method,
        'path': path,
        'params': params,
        'timestamp': time.time(),
        'api_type': 'REST' if 'httpMethod' in event else 'HTTP'
    }
    
    return {
        'statusCode': 200,
        'headers': {
            'Content-Type': 'application/json',
            'X-Custom-Header': 'lab06'
        },
        'body': json.dumps(response_body)
    }
EOF

cd /tmp && zip apigw-handler.zip apigw-handler.py

aws lambda create-function \
  --function-name lab06-apigw-handler \
  --runtime python3.12 \
  --handler apigw-handler.handler \
  --role "$ROLE_ARN" \
  --zip-file fileb:///tmp/apigw-handler.zip \
  --timeout 10 \
  --region eu-west-1 2>/dev/null || \
aws lambda update-function-code \
  --function-name lab06-apigw-handler \
  --zip-file fileb:///tmp/apigw-handler.zip \
  --region eu-west-1

LAMBDA_ARN=$(aws lambda get-function \
  --function-name lab06-apigw-handler \
  --region eu-west-1 \
  --query 'Configuration.FunctionArn' --output text)

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

## Paso 2: REST API

```bash
# 2.1 Crear REST API
REST_ID=$(aws apigateway create-rest-api \
  --name lab06-rest-api \
  --description "Lab 06 — REST API" \
  --region eu-west-1 \
  --query 'id' --output text)

echo "REST API ID: $REST_ID"

# 2.2 Obtener root resource (/)
ROOT_ID=$(aws apigateway get-resources \
  --rest-api-id "$REST_ID" \
  --region eu-west-1 \
  --query 'items[0].id' --output text)

# 2.3 Crear recurso /items
ITEMS_ID=$(aws apigateway create-resource \
  --rest-api-id "$REST_ID" \
  --parent-id "$ROOT_ID" \
  --path-part "items" \
  --region eu-west-1 \
  --query 'id' --output text)

# 2.4 Crear método GET /items
aws apigateway put-method \
  --rest-api-id "$REST_ID" \
  --resource-id "$ITEMS_ID" \
  --http-method GET \
  --authorization-type NONE \
  --region eu-west-1

# 2.5 Integración Lambda Proxy
aws apigateway put-integration \
  --rest-api-id "$REST_ID" \
  --resource-id "$ITEMS_ID" \
  --http-method GET \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri "arn:aws:apigateway:eu-west-1:lambda:path/2015-03-31/functions/$LAMBDA_ARN/invocations" \
  --region eu-west-1

# 2.6 Permiso Lambda para ser invocada por API Gateway
aws lambda add-permission \
  --function-name lab06-apigw-handler \
  --statement-id rest-api-permission \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:eu-west-1:$ACCOUNT_ID:$REST_ID/*/GET/items" \
  --region eu-west-1 2>/dev/null || true

# 2.7 Deploy al stage 'dev'
aws apigateway create-deployment \
  --rest-api-id "$REST_ID" \
  --stage-name dev \
  --region eu-west-1

REST_URL="https://$REST_ID.execute-api.eu-west-1.amazonaws.com/dev/items"
echo "REST API URL: $REST_URL"
```

## Paso 3: HTTP API

```bash
# HTTP API es significativamente más simple de configurar
HTTP_ID=$(aws apigatewayv2 create-api \
  --name lab06-http-api \
  --protocol-type HTTP \
  --target "$LAMBDA_ARN" \
  --region eu-west-1 \
  --query 'ApiId' --output text)

echo "HTTP API ID: $HTTP_ID"

# El --target crea automáticamente una ruta $default → Lambda
# Permiso para HTTP API
aws lambda add-permission \
  --function-name lab06-apigw-handler \
  --statement-id http-api-permission \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:eu-west-1:$ACCOUNT_ID:$HTTP_ID/*/*" \
  --region eu-west-1 2>/dev/null || true

HTTP_URL=$(aws apigatewayv2 get-api \
  --api-id "$HTTP_ID" \
  --region eu-west-1 \
  --query 'ApiEndpoint' --output text)

echo "HTTP API URL: $HTTP_URL/items"
```

## Paso 4: Comparar latencia

```bash
echo "=== Calentando las APIs (evitar cold start Lambda) ==="
curl -s "$REST_URL" > /dev/null
curl -s "$HTTP_URL/items" > /dev/null

echo ""
echo "=== Midiendo latencia REST API (10 requests) ==="
for i in {1..10}; do
  time curl -s "$REST_URL" > /dev/null
done 2>&1 | grep real | awk '{print $2}'

echo ""
echo "=== Midiendo latencia HTTP API (10 requests) ==="
for i in {1..10}; do
  time curl -s "$HTTP_URL/items" > /dev/null
done 2>&1 | grep real | awk '{print $2}'

# Con curl mostrando tiempo de conexión y respuesta
echo ""
echo "=== Detalle de tiempos REST ==="
curl -o /dev/null -s -w "DNS: %{time_namelookup}s | Conexión: %{time_connect}s | TTFB: %{time_starttransfer}s | Total: %{time_total}s\n" "$REST_URL"

echo "=== Detalle de tiempos HTTP ==="
curl -o /dev/null -s -w "DNS: %{time_namelookup}s | Conexión: %{time_connect}s | TTFB: %{time_starttransfer}s | Total: %{time_total}s\n" "$HTTP_URL/items"
```

## Paso 5: Habilitar caching en REST API (feature no disponible en HTTP API)

```bash
# 5.1 Crear stage con cache habilitado
aws apigateway create-stage \
  --rest-api-id "$REST_ID" \
  --stage-name prod \
  --deployment-id "$(aws apigateway get-deployments --rest-api-id $REST_ID --region eu-west-1 --query 'items[0].id' --output text)" \
  --cache-cluster-enabled \
  --cache-cluster-size 0.5 \
  --region eu-west-1

# 5.2 Habilitar caching en el método GET /items
aws apigateway update-stage \
  --rest-api-id "$REST_ID" \
  --stage-name prod \
  --patch-operations \
    op=replace,path=/~1items~1GET/caching/enabled,value=true \
    op=replace,path=/~1items~1GET/caching/ttlInSeconds,value=300 \
  --region eu-west-1

echo "Cache habilitado en REST API (TTL=300s)"
echo "NOTA: el cache tiene coste (~\$0.02/h para 0.5GB) — desactivar tras el lab"
```

## Paso 6: Comparar payload de evento (REST vs HTTP)

```bash
# El evento que recibe Lambda es diferente según el tipo de API

# REST API event (httpMethod, path, etc.)
curl -s "$REST_URL?name=lab&version=1" | python3 -m json.tool

# HTTP API event (requestContext.http.method, rawPath, etc.)
curl -s "$HTTP_URL/items?name=lab&version=1" | python3 -m json.tool
```

## Limpieza

```bash
aws apigateway delete-rest-api --rest-api-id "$REST_ID" --region eu-west-1
aws apigatewayv2 delete-api --api-id "$HTTP_ID" --region eu-west-1
```
