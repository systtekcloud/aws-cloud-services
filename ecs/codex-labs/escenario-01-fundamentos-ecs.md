# Escenario 01 - Fundamentos ECS (base operativa)

## Objetivo

Levantar una API en ECS Fargate desde cero: ECR, Task Definition y ECS Service.

## Servicios AWS

- ECR
- ECS (Cluster, Task Definition, Service)
- CloudWatch Logs

## Paso 1 - Crear repositorio ECR

```bash
aws ecr create-repository \
  --repository-name ${PROJECT_PREFIX}/api \
  --image-scanning-configuration scanOnPush=true \
  --region ${AWS_REGION}
```

### Resultado esperado

- Existe el repo `shopapi/api`.
- Puedes ver su URI con:

```bash
aws ecr describe-repositories \
  --repository-names ${PROJECT_PREFIX}/api \
  --query 'repositories[0].repositoryUri' \
  --output text \
  --region ${AWS_REGION}
```

## Paso 2 - Subir imagen de aplicacion

```bash
aws ecr get-login-password --region ${AWS_REGION} \
  | docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

docker build -t ${PROJECT_PREFIX}-api:1.0.0 ecs/labs/app
docker tag ${PROJECT_PREFIX}-api:1.0.0 ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PROJECT_PREFIX}/api:1.0.0
docker push ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PROJECT_PREFIX}/api:1.0.0
```

### Resultado esperado

- Imagen publicada en ECR con tag `1.0.0`.

## Paso 3 - Crear cluster ECS

```bash
aws ecs create-cluster \
  --cluster-name ${CLUSTER_NAME} \
  --settings name=containerInsights,value=enabled \
  --region ${AWS_REGION}
```

### Resultado esperado

- Cluster `shopapi-cluster` en estado `ACTIVE`.

## Paso 4 - Registrar task definition

Usa esta estructura minima (ajusta `ACCOUNT_ID` y region):

```json
{
  "family": "shopapi-api",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::ACCOUNT_ID:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "shopapi-api",
      "image": "ACCOUNT_ID.dkr.ecr.eu-west-1.amazonaws.com/shopapi/api:1.0.0",
      "essential": true,
      "portMappings": [
        { "containerPort": 8080, "protocol": "tcp" }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/shopapi-api",
          "awslogs-region": "eu-west-1",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
```

Registra la task:

```bash
aws ecs register-task-definition \
  --cli-input-json file://taskdef-v1.json \
  --region ${AWS_REGION}
```

### Resultado esperado

- Nueva revision de `shopapi-api`.

## Paso 5 - Crear ECS Service (2 tareas)

Usa tus subnets y SG validos:

```bash
aws ecs create-service \
  --cluster ${CLUSTER_NAME} \
  --service-name shopapi-service \
  --task-definition shopapi-api \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-aaa,subnet-bbb],securityGroups=[sg-aaa],assignPublicIp=ENABLED}" \
  --region ${AWS_REGION}
```

### Resultado esperado

- `runningCount=2` y `pendingCount=0`.
- Logs visibles en `/ecs/shopapi-api`.

## Validacion final del escenario

```bash
aws ecs describe-services \
  --cluster ${CLUSTER_NAME} \
  --services shopapi-service \
  --query 'services[0].{Desired:desiredCount,Running:runningCount,Status:status}' \
  --output table \
  --region ${AWS_REGION}
```

### Resultado esperado

- Servicio estable y listo para exponer por ALB en el siguiente escenario.
