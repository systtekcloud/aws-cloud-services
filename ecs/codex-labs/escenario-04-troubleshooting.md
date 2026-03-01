# Escenario 04 - Troubleshooting guiado (fallos comunes ECS)

## Objetivo

Practicar diagnostico y resolucion de problemas frecuentes en ECS para examen y vida real.

## Metodologia sugerida

Para cada caso:

1. Provoca el fallo.
2. Observa sintomas (ECS, ALB, CloudWatch, logs).
3. Formula hipotesis.
4. Corrige.
5. Verifica recuperacion.

## Caso 1 - `CannotPullContainerError`

### Simulacion

- Cambia la imagen en Task Definition a un tag inexistente (`:404`).

### Diagnostico

```bash
aws ecs describe-tasks \
  --cluster ${CLUSTER_NAME} \
  --tasks <task-arn> \
  --query 'tasks[0].containers[0].reason' \
  --output text \
  --region ${AWS_REGION}
```

### Correccion

- Revertir a tag valido en ECR.
- Forzar nuevo deployment.

### Resultado esperado

- Tareas vuelven a `RUNNING`.

## Caso 2 - Targets `unhealthy` en ALB

### Simulacion

- Cambia health check path del target group a `/wrong`.

### Diagnostico

```bash
aws elbv2 describe-target-health \
  --target-group-arn <tg-arn> \
  --region ${AWS_REGION}
```

### Correccion

- Restaurar path `/health`.
- Verificar puerto correcto 8080 y reglas SG ALB -> ECS.

### Resultado esperado

- Targets cambian a `healthy`.
- ALB vuelve a entregar trafico sin 5xx.

## Caso 3 - Error de permisos IAM (`AccessDenied`)

### Simulacion

- Quita temporalmente permiso `secretsmanager:GetSecretValue` del execution role.

### Diagnostico

- Eventos del service y logs de inicio muestran acceso denegado.

```bash
aws ecs describe-services \
  --cluster ${CLUSTER_NAME} \
  --services shopapi-service \
  --query 'services[0].events[0:10]' \
  --region ${AWS_REGION}
```

### Correccion

- Restaurar politica IAM minima al rol correspondiente.

### Resultado esperado

- Nuevas tareas arrancan correctamente y leen secretos.

## Caso 4 - Falta de capacidad o subnet sin IPs

### Simulacion

- Limita subnets del servicio a una subnet pequena casi agotada.

### Diagnostico

- Eventos ECS: `RESOURCE:ENI` o errores de placement.

### Correccion

- Reagregar subnets en 3 AZ.
- Reducir tasks temporalmente o ampliar CIDR.

### Resultado esperado

- Scheduling estable sin errores de capacidad.

## Caso 5 - Worker no consume mensajes SQS

### Simulacion

- Elimina permiso `sqs:ReceiveMessage` del task role del worker.

### Diagnostico

- Cola crece, workers en running pero sin progreso.
- Logs muestran `AccessDenied` al consumir.

### Correccion

- Restaurar permisos `ReceiveMessage`, `DeleteMessage`, `ChangeMessageVisibility`, `GetQueueAttributes`.

### Resultado esperado

- Backlog de SQS baja.
- DLQ solo recibe errores reales de procesamiento.

## Comandos de inspeccion rapida (runbook)

```bash
# Estado servicio
aws ecs describe-services --cluster ${CLUSTER_NAME} --services shopapi-service --region ${AWS_REGION}

# Eventos recientes del servicio
aws ecs describe-services --cluster ${CLUSTER_NAME} --services shopapi-service --query 'services[0].events[0:15]' --region ${AWS_REGION}

# Estado targets ALB
aws elbv2 describe-target-health --target-group-arn <tg-arn> --region ${AWS_REGION}

# Backlog de cola
aws sqs get-queue-attributes --queue-url <queue-url> --attribute-names ApproximateNumberOfMessages --region ${AWS_REGION}
```

## Resultado esperado final

- Eres capaz de pasar de sintoma a causa raiz en menos de 15 minutos por caso.
