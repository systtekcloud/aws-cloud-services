# ECS SAA - Ruta Hands-on Progresiva

Este paquete contiene escenarios practicos para estudiar Amazon ECS con foco en AWS Solutions Architect Associate.

## Orden recomendado

1. `escenario-01-fundamentos-ecs.md`
2. `escenario-02-servicio-multiaz-enterprise.md`
3. `escenario-03-integraciones-aws.md`
4. `escenario-04-troubleshooting.md`
5. `escenario-05-optimizacion-costes.md`
6. `escenario-99-cleanup.md`

## Objetivo de la ruta

- Empezar desde ECS basico (ECR + cluster + task + service).
- Evolucionar a arquitectura enterprise multi-AZ.
- Practicar integraciones clave para el examen (ALB, SQS, Secrets Manager, CloudWatch, DynamoDB, EventBridge).
- Simular fallos reales y resolverlos.
- Aplicar tecnicas de optimizacion de costes.
- Cerrar siempre con procedimientos de limpieza.

## Prerrequisitos minimos

```bash
aws --version
docker --version
jq --version
```

## Variables base (ejemplo)

```bash
export AWS_REGION=eu-west-1
export AWS_DEFAULT_REGION=eu-west-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export PROJECT_PREFIX=shopapi
export CLUSTER_NAME=shopapi-cluster
```

## Recomendacion de estudio

- Ejecuta cada escenario en orden.
- No saltes el troubleshooting: ahi consolidas el criterio de arquitecto.
- Al terminar cada sesion, ejecuta `escenario-99-cleanup.md`.
