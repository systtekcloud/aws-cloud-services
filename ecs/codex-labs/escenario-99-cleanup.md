# Escenario 99 - Cleanup total (obligatorio)

## Objetivo

Eliminar recursos creados en los escenarios para evitar costes innecesarios.

## Orden recomendado de borrado

1. Escalar servicios ECS a 0.
2. Eliminar servicios ECS.
3. Eliminar reglas/alarmas/targets de EventBridge y Auto Scaling.
4. Eliminar colas SQS y DLQ.
5. Eliminar ALB, listeners y target groups.
6. Eliminar secretos y tablas DynamoDB de laboratorio.
7. Eliminar endpoints VPC (si los creaste para el lab).
8. Eliminar cluster ECS.
9. Eliminar ECR repo (si no lo necesitas).

## Paso 1 - ECS services a 0 y borrado

```bash
aws ecs update-service --cluster ${CLUSTER_NAME} --service shopapi-service --desired-count 0 --region ${AWS_REGION}
aws ecs update-service --cluster ${CLUSTER_NAME} --service shopapi-worker --desired-count 0 --region ${AWS_REGION}

aws ecs delete-service --cluster ${CLUSTER_NAME} --service shopapi-service --force --region ${AWS_REGION}
aws ecs delete-service --cluster ${CLUSTER_NAME} --service shopapi-worker --force --region ${AWS_REGION}
```

### Resultado esperado

- No quedan servicios activos en el cluster.

## Paso 2 - Eliminar SQS, DynamoDB y Secret

```bash
aws sqs delete-queue --queue-url <shopapi-orders-url> --region ${AWS_REGION}
aws sqs delete-queue --queue-url <shopapi-orders-dlq-url> --region ${AWS_REGION}

aws dynamodb delete-table --table-name shopapi-products --region ${AWS_REGION}

aws secretsmanager delete-secret \
  --secret-id shopapi/prod/db \
  --force-delete-without-recovery \
  --region ${AWS_REGION}
```

### Resultado esperado

- Sin colas, tabla ni secretos de laboratorio.

## Paso 3 - Eliminar ALB y target groups

```bash
aws elbv2 delete-load-balancer --load-balancer-arn <alb-arn> --region ${AWS_REGION}
aws elbv2 delete-target-group --target-group-arn <tg-arn> --region ${AWS_REGION}
```

### Resultado esperado

- ALB eliminado y sin cargos de balanceador.

## Paso 4 - Eliminar cluster ECS

```bash
aws ecs delete-cluster --cluster ${CLUSTER_NAME} --region ${AWS_REGION}
```

### Resultado esperado

- Cluster eliminado.

## Paso 5 - Eliminar ECR (opcional, si no lo reutilizas)

```bash
aws ecr delete-repository \
  --repository-name ${PROJECT_PREFIX}/api \
  --force \
  --region ${AWS_REGION}
```

### Resultado esperado

- Repo ECR eliminado (o conservado de forma intencional).

## Verificacion de cierre

```bash
aws ecs list-clusters --region ${AWS_REGION}
aws elbv2 describe-load-balancers --region ${AWS_REGION}
aws sqs list-queues --region ${AWS_REGION}
```

## Resultado esperado final

- No quedan recursos del laboratorio con coste recurrente.
