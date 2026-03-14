# Lab 05 — 3-Tier Full Stack: Aurora + ElastiCache + DynamoDB

> **Nivel:** AWS SAA-C03 Capstone | **Tiempo total:** ~4h | **Coste estimado:** ~2-3€ (con cleanup al terminar)
> **Prerrequisito:** Labs 01-04 completados (conceptos) + VPC `vpc-db-labs` activa o recrearla aquí.

---

## ¿Qué construyes?

Una arquitectura e-commerce de producción donde **cada servicio de base de datos cumple su función óptima**:

```
Internet
    │
    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Subnets Públicas (10.20.0.0/24, 10.20.1.0/24)                      │
│  [ALB — No incluido en este lab, simulamos con EC2]                 │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────────────┐
│  Subnets Privadas App (10.20.10.0/24, 10.20.11.0/24)                │
│                                                                      │
│  EC2 App Server (simula capa de aplicación)                         │
│      │              │              │                                 │
│      ▼              ▼              ▼                                 │
│  RDS Proxy     ElastiCache    DynamoDB                              │
│  (Aurora)      Redis          (via VPC Endpoint)                    │
│      │                            │                                  │
└──────┼────────────────────────────┼──────────────────────────────────┘
       │                            │
┌──────▼────────────────────────────▼──────────────────────────────────┐
│  Subnets Privadas DB (10.20.20.0/24, 10.20.21.0/24)                  │
│                                                                       │
│  Aurora MySQL Cluster         Redis Replication Group                │
│  (Writer + Reader)            (Primary + Replica)                    │
│  [pedidos, pagos, usuarios]   [sesiones, caché producto]             │
└───────────────────────────────────────────────────────────────────────┘
                 │
                 ▼ (DynamoDB Streams)
         Lambda Function ──► SNS Topic
         [catálogo, carrito, notificaciones]
```

---

## Decisiones de arquitectura justificadas

| Requisito | Servicio elegido | Justificación |
|-----------|-----------------|---------------|
| Pedidos y pagos (ACID, JOINs) | Aurora MySQL | Transacciones, relaciones, histórico |
| Catálogo de productos | DynamoDB | Schema flexible, lectura <10ms, On-Demand |
| Carrito de compra | DynamoDB + TTL | Temporal, K/V simple, expira en 1h |
| Sesiones de usuario | ElastiCache Redis | TTL, compartido entre instancias de app |
| Caché de producto | ElastiCache Redis | Cache-aside, reduce carga Aurora 90% |
| Notificaciones (nuevo pedido) | DynamoDB Streams → Lambda → SNS | Event-driven sin polling |
| Conectar Lambda/ECS → Aurora | RDS Proxy | Connection pooling, sin "too many connections" |
| Acceder DynamoDB sin internet | Gateway VPC Endpoint | Sin egress cost, sin tráfico público |

---

## Estructura del lab

```
lab05-3tier-full-stack/
├── README.md                      ← este archivo
├── fase-01-arquitectura-vpc.md    ← VPC 3-tier con 6 subnets y VPC Endpoints
├── fase-02-aurora-rds-proxy.md    ← Aurora + RDS Proxy + tablas SQL
├── fase-03-dynamodb-lambda.md     ← DynamoDB catálogo/carrito + Streams → Lambda → SNS
├── fase-04-redis-integracion.md   ← Redis sesiones + cache-aside desde EC2
├── fase-05-validacion-e2e.md      ← Flujo completo + CloudWatch Dashboard + DR
├── cleanup.md
├── cli/
│   ├── 00-env.sh
│   ├── 01-vpc-extendida.sh        ← VPC 3-tier (6 subnets)
│   ├── 02-aurora-proxy.sh         ← Aurora + RDS Proxy
│   ├── 03-dynamodb-lambda.sh      ← DynamoDB + Streams + Lambda + SNS
│   ├── 04-redis.sh                ← Redis cluster
│   ├── 05-validacion.sh           ← Prueba e2e del flujo
│   └── 99-cleanup.sh
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
├── terragrunt/
│   └── terragrunt.hcl
└── troubleshooting/
    ├── 01-rds-proxy-errores.md
    ├── 02-vpc-endpoint-dynamodb.md
    └── 03-integracion-servicios.md
```

---

## Recursos creados y costes

| Recurso | Especificación | Coste/hora |
|---------|---------------|-----------|
| Aurora MySQL Writer | db.t3.medium | ~0.073 USD |
| Aurora MySQL Reader | db.t3.medium | ~0.073 USD |
| RDS Proxy | basado en vCPU de la instancia | ~0.015 USD |
| ElastiCache Redis Primary | cache.t3.micro | ~0.034 USD |
| ElastiCache Redis Replica | cache.t3.micro | ~0.034 USD |
| EC2 App Server | t3.micro | ~0.011 USD |
| Lambda | invocations | ~0 (free tier) |
| DynamoDB | PAY_PER_REQUEST | ~0 (vacía) |
| **Total** | | **~0.24 USD/h = ~1.7€ en 7 horas** |

---

## Mapa de aprendizaje SAA-C03

Este lab consolida los conceptos más frecuentes del examen:

- ✅ Aurora Multi-AZ + cluster/reader endpoints
- ✅ RDS Proxy (connection pooling para Lambda/ECS)
- ✅ DynamoDB On-Demand + GSI + TTL
- ✅ DynamoDB Streams → Lambda → SNS (event-driven)
- ✅ Gateway VPC Endpoint para DynamoDB
- ✅ ElastiCache Redis cache-aside + session store
- ✅ Secrets Manager para credenciales de Aurora
- ✅ VPC 3-tier con separación app/db subnets
- ✅ Security Groups en cascada (SG-to-SG rules)
