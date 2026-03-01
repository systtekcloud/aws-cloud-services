# Troubleshooting 05 — Target Type: instancia vs IP vs Lambda

## Síntoma
No se pueden registrar targets en el Target Group. O las instancias ECS/Fargate no registran. O el error es `InvalidTarget`.

## Diagnóstico

```bash
source ~/.ec2-lab-env

# 1. Verificar el target type del TG
aws elbv2 describe-target-groups \
  --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[0].{TargetType:TargetType,Port:Port,Protocol:Protocol}' \
  --output table

# 2. Intentar registrar un target y ver el error
# Ejemplo: registrar por instancia-id (solo funciona si target-type=instance)
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)

aws elbv2 register-targets \
  --target-group-arn "$TG_ARN" \
  --targets Id="$INSTANCE_ID",Port=8080

# 3. Para ECS/Fargate (target-type=ip): los targets son IPs de ENI de la task
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[*].[Target.Id,Target.Port,TargetHealth.State]' \
  --output table
```

## Tabla de target types

| Target Type | Targets | Uso |
|---|---|---|
| `instance` | EC2 Instance IDs | EC2 + ASG clásico |
| `ip` | IPs privadas (ENI) | ECS/Fargate, Lambda en VPC, on-prem vía PrivateLink |
| `lambda` | ARN de Lambda | Lambda sin VPC |

## Error `InvalidTarget`

Ocurre cuando:
1. Intentas registrar una instancia en un TG de tipo `ip` (o viceversa)
2. La instancia no está en la misma VPC que el ALB
3. La IP de destino no está en una subnet válida

```bash
# Verificar: ¿el TG es del tipo correcto para el workload?
# Para ASG → target-type=instance
# Para ECS (awsvpc) → target-type=ip
# NO SE PUEDE CAMBIAR el target-type después de crear el TG
# → Hay que crear un TG nuevo con el tipo correcto
```

## Solución cuando el target type es incorrecto

```bash
# Crear TG nuevo con el tipo correcto
TG_NEW=$(aws elbv2 create-target-group \
  --name "${PROJECT}-tg-v2" \
  --protocol HTTP \
  --port 8080 \
  --vpc-id "$VPC_ID" \
  --target-type instance \   # ← tipo correcto
  --health-check-path "/health" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Actualizar el listener para apuntar al nuevo TG
aws elbv2 modify-listener \
  --listener-arn "$LISTENER_ARN" \
  --default-actions "Type=forward,TargetGroupArn=$TG_NEW"

# Actualizar el ASG
aws autoscaling attach-load-balancer-target-groups \
  --auto-scaling-group-name "$ASG_NAME" \
  --target-group-arns "$TG_NEW"
```

## Exam Trap
El `target-type` de un Target Group es **inmutable** — no se puede modificar una vez creado. Si te equivocas, debes crear un nuevo Target Group. En el examen, si ves ECS con `awsvpc` network mode → siempre `target-type=ip`. Si ves EC2 + ASG → siempre `target-type=instance`.
