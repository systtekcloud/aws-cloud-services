# Escenario 05 - Optimizacion de costes en ECS

## Objetivo

Reducir coste de red, computo y observabilidad manteniendo disponibilidad.

## Palancas de optimizacion

1. VPC Endpoints para trafico privado a AWS.
2. Capacity Providers con FARGATE + FARGATE_SPOT.
3. Right sizing de CPU/memoria por servicio.
4. Politicas de retencion de logs.
5. Escalado programado (apagar capacidad fuera de horario).

## Paso 1 - Baseline de coste

Toma captura de referencia en Cost Explorer (7 o 30 dias):

- ECS/Fargate
- VPC (NAT Gateway)
- CloudWatch Logs

### Resultado esperado

- Tienes una linea base para comparar ahorro.

## Paso 2 - VPC Endpoints (evitar NAT para ECR/Logs/Secrets)

Crear endpoints:

- `com.amazonaws.${AWS_REGION}.ecr.api`
- `com.amazonaws.${AWS_REGION}.ecr.dkr`
- `com.amazonaws.${AWS_REGION}.logs`
- `com.amazonaws.${AWS_REGION}.secretsmanager`
- `com.amazonaws.${AWS_REGION}.s3` (gateway)

### Resultado esperado

- Menos bytes por NAT Gateway en CloudWatch metricas.
- Pull de imagen y logs via red privada.

## Paso 3 - Capacity provider strategy en workers

Ejemplo recomendado:

- `FARGATE`: `base=1`, `weight=1`
- `FARGATE_SPOT`: `base=0`, `weight=3`

```bash
aws ecs update-service \
  --cluster ${CLUSTER_NAME} \
  --service shopapi-worker \
  --capacity-provider-strategy capacityProvider=FARGATE,base=1,weight=1 capacityProvider=FARGATE_SPOT,base=0,weight=3 \
  --force-new-deployment \
  --region ${AWS_REGION}
```

### Resultado esperado

- Mayor parte de workers en Spot.
- Coste de compute del worker baja significativamente.

## Paso 4 - Right sizing de task definitions

Accion:

- Revisa `CPUUtilization` y `MemoryUtilization` p95.
- Si uso p95 < 40%, baja un nivel (ejemplo 512/1024 -> 256/512) y valida.

### Resultado esperado

- Menor coste por hora por task sin degradar latencia/SLA.

## Paso 5 - Retencion de logs

```bash
aws logs put-retention-policy \
  --log-group-name /ecs/shopapi-api \
  --retention-in-days 14 \
  --region ${AWS_REGION}
```

Define retencion distinta por entorno:

- dev: 7 dias
- staging: 14 dias
- prod: 30-90 dias

### Resultado esperado

- Coste de almacenamiento de logs controlado y predecible.

## Paso 6 - Escalado programado fuera de horario

Reducir minimo nocturno en entornos no productivos:

```bash
aws application-autoscaling put-scheduled-action \
  --service-namespace ecs \
  --resource-id service/${CLUSTER_NAME}/shopapi-service \
  --scalable-dimension ecs:service:DesiredCount \
  --scheduled-action-name shopapi-night-scale-down \
  --schedule "cron(0 22 ? * MON-FRI *)" \
  --scalable-target-action MinCapacity=1,MaxCapacity=3 \
  --region ${AWS_REGION}
```

### Resultado esperado

- Menor gasto en horas valle sin impacto en horas pico.

## Cierre del escenario - Medir ahorro

Compara contra el baseline inicial:

- NAT bytes/dia antes y despues.
- Costo Fargate vs Fargate Spot.
- Costo CloudWatch Logs.

### Resultado esperado final

- Evidencia cuantitativa de ahorro y decisiones de arquitectura defendibles en entrevista/examen.
