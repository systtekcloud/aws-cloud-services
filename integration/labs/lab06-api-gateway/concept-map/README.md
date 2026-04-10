# API Gateway — Concept Map

## ¿Qué es API Gateway?

Amazon API Gateway es un servicio gestionado para crear, publicar, mantener y securizar APIs a cualquier escala. Actúa como "puerta de entrada" entre los clientes y tus backends (Lambda, HTTP, servicios AWS).

---

## Tres tipos de API

```
┌─────────────────────────────────────────────────────────────────┐
│  REST API                                                        │
│  • El más completo y configurable                                │
│  • Caching, request validation, usage plans, API Keys           │
│  • WAF integration nativa                                        │
│  • Precio: $3.50/M requests + $0.09/GB transfer                 │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  HTTP API                                                        │
│  • Más rápido (~60% menos latencia) y más barato ($1.00/M)      │
│  • JWT authorization nativa (sin Lambda authorizer)              │
│  • OIDC integration directa                                      │
│  • Sin caching, sin usage plans, sin WAF nativo                  │
│  • Ideal para: microservicios, backends privados                 │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  WebSocket API                                                   │
│  • Conexiones bidireccionales persistentes                       │
│  • Routes: $connect, $disconnect, $default + custom              │
│  • Casos: chat, dashboards real-time, gaming                     │
│  • Precio: $1.00/M mensajes + $0.25/M connection-minutes        │
└─────────────────────────────────────────────────────────────────┘
```

---

## REST API vs HTTP API — tabla comparativa completa

| Feature | REST API | HTTP API |
|---------|----------|----------|
| Precio base | $3.50/M | $1.00/M |
| Latencia | ~6ms overhead | ~2ms overhead |
| Caching | ✓ (TTL configurable) | ✗ |
| Request Validation | ✓ (JSON Schema) | ✗ |
| Usage Plans + API Keys | ✓ | ✗ |
| WAF Integration | ✓ | ✗ |
| Lambda Authorizer | ✓ | ✓ |
| JWT/OIDC nativo | ✗ (via Lambda auth) | ✓ |
| Cognito nativo | ✓ | ✓ |
| Mock integration | ✓ | ✗ |
| AWS Service integration | ✓ (directa) | ✗ |
| VPC Link | ✓ (NLB) | ✓ (NLB + ALB) |
| CORS | Manual | Automático |
| OpenAPI import | ✓ | ✓ |

**Regla de decisión:**
- Necesitas caching, usage plans, o WAF → **REST API**
- Quieres JWT nativo y no necesitas las features avanzadas → **HTTP API**
- Backend bidireccional en tiempo real → **WebSocket API**

---

## Tipos de integración

```
Lambda Proxy Integration (más común):
  API GW → Lambda → respuesta completa del handler
  Lambda devuelve: { statusCode, headers, body }

HTTP Proxy Integration:
  API GW → reenvía request a URL HTTP externo
  Sin transformación — API GW actúa como proxy puro

AWS Service Integration (solo REST):
  API GW → llama directamente a servicio AWS (SQS, DynamoDB, SNS)
  Sin Lambda intermedia — más barato y menos latencia

Mock Integration (solo REST):
  API GW → responde directamente sin backend
  Útil para: mockear endpoints durante desarrollo
```

---

## Autenticación y Autorización

```
┌────────────────────────────────────────────────────────┐
│ API Keys + Usage Plans (REST)                           │
│  • Identifica el cliente (no el usuario)               │
│  • Limita: requests/segundo y requests/mes              │
│  • Uso: APIs B2B, throttling por tier (free/pro)       │
└────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────┐
│ Lambda Authorizer                                       │
│  • Token-based: valida JWT/Bearer en header            │
│  • Request-based: accede a headers/query/path params   │
│  • Devuelve: IAM policy (Allow/Deny) + context         │
│  • TTL de policy cacheada: 300s default                │
└────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────┐
│ Cognito User Pools (REST + HTTP)                        │
│  • Valida JWT de Cognito automáticamente               │
│  • Sin Lambda authorizer necesario                     │
│  • La API recibe el token validado en headers          │
└────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────┐
│ JWT Authorizer (HTTP API nativo)                        │
│  • Valida JWT de cualquier OIDC provider               │
│  • Cognito, Auth0, Okta, etc.                          │
│  • Configuras: issuer URL + audience                   │
└────────────────────────────────────────────────────────┘
```

---

## Throttling — niveles y precedencia

```
Account-level (default): 10.000 req/s, burst 5.000
      │
Stage-level: puedes bajar el límite por stage (prod/dev)
      │
Method-level: puedes bajar por ruta específica (POST /pagos)
      │
Usage Plan: límite por API Key (cliente específico)

Precedencia: el límite más restrictivo aplica
```

Cuando se supera: HTTP 429 Too Many Requests con header `x-amzn-ErrorType: TooManyRequestsException`.

---

## VPC Link — acceso a backends privados

```
Internet → API Gateway → VPC Link → NLB (privado) → ECS/EC2/RDS
                                    (subnet privada)
```

VPC Link permite que API Gateway llame a backends en una VPC privada sin exponer esos backends a internet.

---

## Stages y Deployment

```
API Definition (recursos, métodos, integraciones)
      │
      ▼ Deploy
  [Stage: dev]   → https://api-id.execute-api.region.amazonaws.com/dev/
  [Stage: prod]  → https://api-id.execute-api.region.amazonaws.com/prod/

Variables de stage: ${stageVariables.backendUrl}
  → permite apuntar cada stage a un backend diferente sin cambiar la API
```

---

## Pricing

```
REST API:  $3.50 por millón de requests (primeros 333M/mes)
           + $0.09/GB de datos transferidos

HTTP API:  $1.00 por millón de requests (primeros 300M/mes)
           + $0.09/GB de datos transferidos

WebSocket: $1.00 por millón de mensajes
           + $0.25 por millón de minutos de conexión

Cache:     $0.020–$3.800/hora según tamaño (0.5GB a 237GB)
```
