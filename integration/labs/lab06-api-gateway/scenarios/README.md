# Lab 06 — Scenarios: API Gateway en decisiones de arquitectura

## Scenario 1: REST vs HTTP API — árbol de decisión real

```
¿Necesitas caching de respuestas?            → REST API
¿Necesitas Usage Plans + API Keys por tier?  → REST API
¿Necesitas WAF integrado nativamente?        → REST API
¿Necesitas request validation con JSON Schema? → REST API
¿Quieres JWT/OIDC sin Lambda Authorizer?     → HTTP API
¿Necesitas CORS automático?                  → HTTP API
¿Precio y latencia son prioritarios?         → HTTP API
¿Ninguna feature avanzada necesaria?         → HTTP API (más barato)

REST API cuesta 3.5x más que HTTP API.
La diferencia se nota a millones de requests.
```

## Scenario 2: Lambda Authorizer vs Cognito vs IAM

| Caso | Auth recomendada | Por qué |
|------|------------------|---------|
| API pública con usuarios propios | Cognito User Pools | Gestión de usuarios integrada |
| API B2B con clientes identificados | API Keys + Usage Plans | Control por cliente + throttling |
| API interna entre microservicios | IAM Auth (SigV4) | Sin overhead de tokens, seguro en VPC |
| Auth custom (LDAP, base de datos) | Lambda Authorizer | Lógica propia de validación |
| JWT de terceros (Auth0, Okta) | HTTP API JWT Authorizer | Validación nativa, sin Lambda |

## Scenario 3: API Gateway vs ALB para backends Lambda

| Criterio | API Gateway | ALB |
|----------|-------------|-----|
| Precio | $3.50/M (REST) | $0.008/h + $0.008/LCU |
| Auth nativa | ✓ (múltiples opciones) | Cognito solo |
| Throttling | ✓ | ✗ |
| Usage Plans | ✓ | ✗ |
| Caching | ✓ | ✗ |
| WebSocket | ✓ | ✗ |
| Latencia | ~6ms overhead | ~1ms overhead |
| Traffic <1M req/mes | API GW más barato | ALB mínimo $5.76/mes |
| Traffic >10M req/mes | ALB puede ser más barato | Depende de LCUs |

**Para APIs internas o microservicios sin auth compleja a alto tráfico:** ALB puede ser más barato. Para APIs públicas con throttling y auth: API Gateway.

## Scenario 4: Throttling como protección de downstream

```
Caso: Lambda que llama a RDS con 20 conexiones máximas

Sin throttling:
  1000 req/s × Lambda → 1000 conexiones a RDS → RDS colapsa

Con API GW throttling + Lambda reserved concurrency:
  API GW: 100 req/s (rate_limit) + 200 burst
  Lambda: reserved_concurrency = 15
  → RDS recibe máximo 15 queries simultáneas → estable

La combinación API GW throttling + Lambda reserved concurrency
es la solución estándar para proteger bases de datos de picos.
```
