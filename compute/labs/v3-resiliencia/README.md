# v3 — Resiliencia: Scaling, Fault Injection y Blue/Green

Extiende v1+v2 añadiendo políticas de scaling avanzadas, Warm Pool para reducir latencia de scale-out, pruebas de resiliencia con AWS Fault Injection Simulator y despliegues Blue/Green sin TTL usando Weighted Target Groups.

```
                     ALB Listener (:80)
                          │
              ┌───────────┴───────────┐
         TG-Blue (90%)           TG-Green (10%)
              │                        │
         ASG-Blue                  ASG-Green
    (producción actual)         (nueva versión)
              │
         Warm Pool
    (instancias pre-calentadas)
```

**Patrón Blue/Green con ALB:** Sin TTL de DNS — el corte se hace en el listener en segundos. Rollback instantáneo cambiando pesos de vuelta.

---

## Fase A — CLI

```bash
source ~/.ec2-lab-env
bash cli/01-scaling-policies.sh   # Step scaling + Scheduled
bash cli/02-warm-pool.sh          # Warm Pool para scale-out rápido
bash cli/03-fault-injection.sh    # FIS experiment: terminate EC2
bash cli/04-blue-green.sh         # Weighted TGs para Blue/Green
```

### Cleanup
```bash
bash cli/99-cleanup.sh
```

---

## Fase B — Terraform

```bash
cd terraform/
terraform init
terraform plan \
  -var="asg_name=$ASG_NAME" \
  -var="tg_blue_arn=$TG_ARN" \
  -var="alb_listener_arn=$LISTENER_ARN"
terraform apply
```

---

## Resultados esperados

- `aws autoscaling describe-warm-pool` → instancias en estado `Warmed:Stopped`
- FIS experiment: instancias terminadas, ASG repone en <2 min desde Warm Pool
- Blue/Green: `TG-Blue=90%, TG-Green=10%` → corte a 100%/0% sin interrupción
- Scheduled scaling: `min=4` en horario pico (ej. 08:00-20:00 UTC)

---

## Exam Traps

| Trampa | Realidad |
|---|---|
| Warm Pool = Auto Scaling estándar | Warm Pool mantiene instancias pre-inicializadas en `Stopped`; el scale-out tarda <30s |
| Blue/Green con Route53 tiene corte instantáneo | Route53 tiene TTL; el corte real tarda TTL segundos. ALB Weighted TGs sí son instantáneos |
| FIS termina instancias permanentemente | FIS experimento controlado; ASG repone automáticamente |
| Step Scaling y Target Tracking al mismo tiempo | Pueden coexistir; Target Tracking gestiona steady state, Step Scaling para picos abruptos |
| Instance Refresh borra todas las instancias a la vez | `MinHealthyPercentage=50` garantiza mitad activa durante el refresh |
