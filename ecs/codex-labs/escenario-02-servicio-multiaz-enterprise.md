# Escenario 02 - ECS Service enterprise multi-AZ

## Objetivo

Convertir el servicio base en arquitectura enterprise:

- ALB en subnets publicas
- ECS en subnets privadas
- 3 AZ para alta disponibilidad
- Auto Scaling del servicio

## Servicios AWS

- VPC
- ALB + Target Group
- ECS Service
- Application Auto Scaling

## Paso 1 - Verificar topologia de red 3 AZ

Debes tener:

- Publicas: `shopapi-public-a`, `shopapi-public-b`, `shopapi-public-c`
- Privadas: `shopapi-private-a`, `shopapi-private-b`, `shopapi-private-c`

```bash
aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=shopapi-public-a,shopapi-public-b,shopapi-public-c,shopapi-private-a,shopapi-private-b,shopapi-private-c" \
  --query 'Subnets[*].{Name:Tags[?Key==`Name`]|[0].Value,AZ:AvailabilityZone,Subnet:SubnetId}' \
  --output table \
  --region ${AWS_REGION}
```

### Resultado esperado

- Seis subnets en 3 AZ.

## Paso 2 - Crear ALB + Target Group

```bash
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name shopapi-alb \
  --subnets subnet-public-a subnet-public-b subnet-public-c \
  --security-groups sg-alb \
  --scheme internet-facing \
  --type application \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text \
  --region ${AWS_REGION})

TG_ARN=$(aws elbv2 create-target-group \
  --name shopapi-tg \
  --protocol HTTP \
  --port 8080 \
  --target-type ip \
  --vpc-id vpc-xxxx \
  --health-check-path /health \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text \
  --region ${AWS_REGION})
```

Crear listener:

```bash
aws elbv2 create-listener \
  --load-balancer-arn ${ALB_ARN} \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=${TG_ARN} \
  --region ${AWS_REGION}
```

### Resultado esperado

- ALB `active`.
- Listener HTTP:80 enviando a `shopapi-tg`.

## Paso 3 - Actualizar ECS Service en subnets privadas + ALB

```bash
aws ecs update-service \
  --cluster ${CLUSTER_NAME} \
  --service shopapi-service \
  --desired-count 3 \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-priv-a,subnet-priv-b,subnet-priv-c],securityGroups=[sg-ecs],assignPublicIp=DISABLED}" \
  --load-balancers "targetGroupArn=${TG_ARN},containerName=shopapi-api,containerPort=8080" \
  --region ${AWS_REGION}
```

### Resultado esperado

- `runningCount=3` distribuidas en varias AZ.
- Targets `healthy` en el target group.

## Paso 4 - Activar Auto Scaling (target tracking)

```bash
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id service/${CLUSTER_NAME}/shopapi-service \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 2 \
  --max-capacity 10 \
  --region ${AWS_REGION}
```

Policy por CPU:

```bash
aws application-autoscaling put-scaling-policy \
  --policy-name shopapi-api-cpu-tt \
  --service-namespace ecs \
  --resource-id service/${CLUSTER_NAME}/shopapi-service \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{"TargetValue":55.0,"PredefinedMetricSpecification":{"PredefinedMetricType":"ECSServiceAverageCPUUtilization"},"ScaleOutCooldown":60,"ScaleInCooldown":180}' \
  --region ${AWS_REGION}
```

### Resultado esperado

- Scalable target creado.
- Policy activa y visible en Application Auto Scaling.

## Paso 5 - Validar continuidad ante fallo AZ

Simula indisponibilidad de una AZ deteniendo tareas en esa AZ.

```bash
aws ecs list-tasks \
  --cluster ${CLUSTER_NAME} \
  --service-name shopapi-service \
  --region ${AWS_REGION}
```

Deten una task de una AZ y revisa reposicion:

```bash
aws ecs stop-task \
  --cluster ${CLUSTER_NAME} \
  --task <task-arn> \
  --reason "simulacion-fallo-az" \
  --region ${AWS_REGION}
```

### Resultado esperado

- ECS repone la task automaticamente.
- Servicio permanece disponible por ALB.

## Validacion final del escenario

```bash
aws ecs describe-services \
  --cluster ${CLUSTER_NAME} \
  --services shopapi-service \
  --query 'services[0].{Desired:desiredCount,Running:runningCount,Deployments:length(deployments)}' \
  --output table \
  --region ${AWS_REGION}
```

### Resultado esperado

- Servicio resiliente y escalable, base de arquitectura enterprise.
