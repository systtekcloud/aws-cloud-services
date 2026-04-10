# Lab 06: Amazon API Gateway

API Gateway es la "puerta de entrada" de tus APIs en AWS. Gestiona autenticación, throttling, caching y routing entre clientes y backends sin gestionar servidores.

---

## Sub-labs

| Sub-lab | Contenido | Tiempo |
|---------|-----------|--------|
| [01-rest-vs-http](labs/01-rest-vs-http/) | Crear REST y HTTP API con mismo Lambda backend, comparar latencia, habilitar caching | 45 min |
| [02-auth-throttling](labs/02-auth-throttling/) | Lambda Authorizer token-based, API Keys + Usage Plans, throttling 429 | 50 min |

---

## Conceptos clave

| Concepto | Resumen |
|----------|---------|
| REST API | Más features (caching, Usage Plans, WAF). $3.50/M |
| HTTP API | Más rápido y barato ($1.00/M), JWT nativo, CORS automático |
| Lambda Proxy | API GW pasa todo el request a Lambda como evento JSON |
| Lambda Authorizer | Valida tokens con lógica custom. Devuelve IAM policy |
| JWT Authorizer | HTTP API valida JWT de Cognito/Auth0/Okta sin Lambda |
| API Key + Usage Plan | Throttling y quota por cliente (B2B) |
| Stage | Versión de despliegue (dev/prod). Variables por stage |
| VPC Link | API GW accede a backends en VPC privada vía NLB |

---

## Terraform quickstart

```bash
cd terraform/
terraform init && terraform apply

REST_URL=$(terraform output -raw rest_api_url)
HTTP_URL=$(terraform output -raw http_api_url)
API_KEY=$(terraform output -raw api_key_value)

# REST (necesita API Key y Authorization header)
curl -H "Authorization: token-admin" -H "x-api-key: $API_KEY" "$REST_URL"

# HTTP (sin auth en este lab)
curl "$HTTP_URL"
```

---

## Recursos

- [concept-map/](concept-map/) — REST vs HTTP vs WebSocket, integraciones, auth, throttling, VPC Link, pricing
- [scenarios/](scenarios/) — REST vs HTTP árbol de decisión, Auth comparativa, API GW vs ALB
- [terraform/](terraform/) — REST API (authorizer + usage plan) + HTTP API (JWT CORS)
- [cleanup.md](cleanup.md)
- [API Gateway Developer Guide](https://docs.aws.amazon.com/apigateway/latest/developerguide/)
