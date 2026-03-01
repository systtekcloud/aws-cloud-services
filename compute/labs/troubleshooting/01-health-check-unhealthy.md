# Troubleshooting 01 — Target Group: instancias Unhealthy

## Síntoma
El ALB devuelve 503. Las instancias del ASG están en `InService` pero el Target Group las marca como `unhealthy`.

## Diagnóstico

```bash
source ~/.ec2-lab-env

# 1. Estado de los targets
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State,TargetHealth.Reason,TargetHealth.Description]' \
  --output table

# 2. Verificar configuración del health check
aws elbv2 describe-target-groups \
  --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[0].{Port:HealthCheckPort,Path:HealthCheckPath,Matcher:Matcher.HttpCode,Interval:HealthCheckIntervalSeconds}' \
  --output table

# 3. Conectar a la instancia por SSM y probar el endpoint directamente
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)

aws ssm start-session --target "$INSTANCE_ID"
# Dentro: curl -v http://localhost:8080/health
```

## Causas comunes

| Causa | Indicador | Solución |
|---|---|---|
| App no arrancada | `curl localhost:8080` → `Connection refused` | `systemctl status app` → `systemctl restart app` |
| Path de health check incorrecto | Configurado `/` pero app responde `/health` | Actualizar TG: `--health-check-path /health` |
| Puerto incorrecto | TG en 80, app escucha en 8080 | Actualizar TG: `--health-check-port 8080` |
| Matcher HTTP incorrecto | App devuelve 200 pero matcher es `301` | Actualizar matcher: `--matcher HttpCode=200` |
| SG bloquea el health check | ALB SG no tiene salida al puerto de la app | Verificar SG de EC2: debe aceptar desde SG del ALB |
| `health-check-grace-period` demasiado corto | Instancias marcadas unhealthy antes de que la app arranque | Aumentar a 120-180s |

## Comandos de solución rápida

```bash
# Corregir path del health check
aws elbv2 modify-target-group \
  --target-group-arn "$TG_ARN" \
  --health-check-path "/health" \
  --health-check-port "8080" \
  --matcher HttpCode=200

# Ver logs de la app en la instancia (vía SSM)
aws ssm send-command \
  --targets "Key=tag:aws:autoscaling:groupName,Values=$ASG_NAME" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["journalctl -u app -n 50 --no-pager"]' \
  --query 'Command.CommandId' --output text
```

## Exam Trap
El health check del ALB (HTTP) es independiente del health check del ASG (EC2). Si el ASG usa `health-check-type=ELB` y el target está `unhealthy`, el ASG terminará la instancia y lanzará una nueva. Si está en `health-check-type=EC2`, el ASG no actúa sobre fallos de app — solo sobre fallos de instancia.
