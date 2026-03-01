# Troubleshooting 04 — ALB Listener Rules: tráfico no enrutado correctamente

## Síntoma
Las peticiones a `/api/*` van al Target Group equivocado, o las reglas del listener no hacen match correctamente. O el listener HTTPS devuelve un certificado diferente al esperado.

## Diagnóstico

```bash
source ~/.ec2-lab-env

ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${PROJECT}-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# 1. Listar todos los listeners
aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[*].[ListenerArn,Port,Protocol,DefaultActions[0].Type]' \
  --output table

# 2. Reglas de un listener (prioridad importa)
LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query "Listeners[?Port==\`443\`].ListenerArn" --output text)

aws elbv2 describe-rules \
  --listener-arn "$LISTENER_ARN" \
  --query 'Rules[*].{Priority:Priority,Conditions:Conditions[0],Actions:Actions[0].Type}' \
  --output table

# 3. Certificados del listener HTTPS
aws elbv2 describe-listener-certificates \
  --listener-arn "$LISTENER_ARN"
```

## Reglas de prioridad en ALB

Las reglas se evalúan en orden ascendente de prioridad (menor número = mayor prioridad). La regla `default` (priority: `default`) se evalúa siempre al final.

```
Prioridad 1: path-pattern /api/* → TG-API
Prioridad 2: path-pattern /static/* → TG-Static
Prioridad default: → TG-Main
```

## Causas comunes

| Causa | Solución |
|---|---|
| Regla más específica tiene prioridad más alta (número mayor) | Reordenar: `aws elbv2 set-rule-priorities --rule-priorities RuleArn=...,Priority=1` |
| Path pattern sin trailing slash: `/api` no hace match con `/api/v1` | Usar `/api/*` (con asterisco) |
| Header condition case-sensitive | ALB path matching es case-sensitive |
| Certificado SNI incorrecto | Añadir certificado al listener: `aws elbv2 add-listener-certificates` |
| Blue/Green: Weighted TGs con peso 0 no reciben tráfico pero siguen activos | Peso 0 = sin tráfico pero el TG sigue registrado |

## Exam Trap
Las reglas de ALB se evalúan **de menor a mayor prioridad numérica**. La regla `default` siempre se evalúa última. Si tienes dos reglas que pueden hacer match (ej. `/api/*` y `/*`), la que tenga **número de prioridad menor** (ej. 1) tiene prioridad sobre la que tiene número mayor (ej. 100). Es fácil confundirse: prioridad 1 = más prioritaria, no menos.
