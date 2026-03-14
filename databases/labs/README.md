# AWS Databases — Labs Progresivos (SAA-C03)

> **Objetivo**: Practicar las decisiones clave de bases de datos en AWS mediante labs progresivos.
> **Región**: eu-west-1 | **Presupuesto máximo**: ~25€/mes (labs diseñados para run & cleanup)
> **Nivel**: AWS Solutions Architect Associate

---

## Mapa de labs

```
databases/labs/
│
├── lab01-rds-basico/       ← RDS MySQL: subnets privadas, KMS, Secrets Manager
│   ├── fase-00-preparacion.md    VPC mínima, SGs, alarms de coste
│   ├── fase-01-rds-seguridad.md  RDS en private subnet + cifrado + secrets
│   ├── fase-02-ha-replicas.md    Multi-AZ + Read Replica: HA vs performance
│   ├── cli/                      Scripts AWS CLI paso a paso
│   ├── terraform/                IaC equivalente
│   ├── troubleshooting/          9 escenarios reales con síntoma→causa→fix
│   └── cleanup.md
│
├── lab02-aurora/           ← Aurora MySQL: cluster, failover, Global DB
│   ├── fase-01-aurora-cluster.md Aurora vs RDS: cuándo Aurora gana
│   ├── fase-02-failover-scaling.md Failover <30s + read scaling + Serverless
│   ├── cli/
│   ├── terraform/
│   ├── troubleshooting/
│   └── cleanup.md
│
├── lab03-dynamodb/         ← DynamoDB: modelado, capacity, GSIs, TTL, Streams
│   ├── fase-01-modelado.md       Diseño PK/SK, hot partitions, GSI
│   ├── fase-02-capacity.md       On-demand vs Provisioned, throttling, autoscaling
│   ├── fase-03-streams-ttl.md    TTL + Streams + Lambda trigger
│   ├── cli/
│   ├── terraform/
│   ├── troubleshooting/
│   └── cleanup.md
│
└── lab04-elasticache/      ← ElastiCache Redis: cache-aside, sesiones, HA
    ├── fase-01-redis-setup.md    Cluster Redis, Multi-AZ, seguridad
    ├── fase-02-cache-aside.md    Patrón cache-aside + hit/miss + TTL
    ├── cli/
    ├── terraform/
    ├── troubleshooting/
    └── cleanup.md
```

---

## Ruta de aprendizaje recomendada

```
┌─────────────────────────────────────────────────────────────────┐
│  PREREQUISITO: VPC con subnets privadas (lab01/fase-00)         │
│  O reusar VPC del lab VPC (vpc/labs/lab01-vpc)                  │
└─────────────────────────────┬───────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
        ┌──────────┐   ┌──────────┐   ┌──────────────┐
        │ Lab01    │   │ Lab03    │   │ Lab04        │
        │ RDS      │   │ DynamoDB │   │ ElastiCache  │
        │ (SQL HA) │   │ (NoSQL)  │   │ (Cache)      │
        └────┬─────┘   └──────────┘   └──────────────┘
             │
             ▼
        ┌──────────┐
        │ Lab02    │
        │ Aurora   │
        │ (cuando  │
        │ RDS < )  │
        └──────────┘
```

**Nota**: Lab01 es prerequisito de Lab02. Lab03 y Lab04 son independientes.

---

## Convención de nombres y tags

Todos los recursos del lab siguen este estándar:

```
Nombre:  db-lab-{servicio}-{recurso}
         Ejemplo: db-lab-rds-instance, db-lab-aurora-cluster

Tags obligatorios:
  Project:   db-labs
  Lab:       lab01 | lab02 | lab03 | lab04
  ManagedBy: console | cli | terraform
  Env:       lab
```

---

## Estimación de coste por lab

| Lab | Recursos principales | Coste aprox./hora | Con cleanup inmediato |
|-----|---------------------|-------------------|-----------------------|
| Lab01 | RDS t3.micro + EC2 t3.micro | ~0.05€/h | < 1€ |
| Lab02 | Aurora t3.medium (min) | ~0.08€/h | < 2€ |
| Lab03 | DynamoDB on-demand + Lambda | ~0.001€/1K req | < 0.50€ |
| Lab04 | ElastiCache t3.micro | ~0.02€/h | < 0.50€ |

> **Regla de oro**: Ejecuta el script `99-cleanup.sh` o `cleanup.md` al finalizar cada lab.
> Un lab olvidado overnight puede costar 1-3€.

---

## Prerequisitos comunes

- AWS CLI configurado (`aws configure`)
- Permisos IAM: AdministratorAccess o política custom con RDS, DynamoDB, ElastiCache, EC2, VPC, IAM, SecretsManager
- Terraform >= 1.5.0 (para la ruta IaC)
- `jq` instalado (para procesar JSON en scripts CLI)

```bash
# Verificar prerequisitos
aws sts get-caller-identity
aws --version
terraform --version
jq --version
```
