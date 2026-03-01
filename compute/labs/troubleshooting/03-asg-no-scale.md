# Troubleshooting 03 — ASG no escala cuando debería

## Síntoma
La CPU supera el 80%, las alarmas CloudWatch están en ALARM, pero el ASG no añade instancias. O las instancias están en `desired` pero no se reducen.

## Diagnóstico

```bash
source ~/.ec2-lab-env

# 1. Estado del ASG
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].{Min:MinSize,Max:MaxSize,Desired:DesiredCapacity,Instances:length(Instances)}' \
  --output table

# 2. Actividad reciente del ASG
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name "$ASG_NAME" \
  --max-items 10 \
  --query 'Activities[*].[StatusCode,Description,StatusMessage]' \
  --output table

# 3. Estado de las alarmas CW vinculadas
aws cloudwatch describe-alarms \
  --alarm-name-prefix "$ASG_NAME" \
  --query 'MetricAlarms[*].[AlarmName,StateValue,StateReason]' \
  --output table

# 4. Políticas de scaling
aws autoscaling describe-policies \
  --auto-scaling-group-name "$ASG_NAME" \
  --query 'ScalingPolicies[*].[PolicyName,PolicyType,AdjustmentType,Enabled]' \
  --output table

# 5. Suspension de procesos (puede bloquear scaling)
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].SuspendedProcesses'
```

## Causas comunes

| Causa | Indicador | Solución |
|---|---|---|
| ASG en `max` | `Desired=Max` | Aumentar MaxSize |
| Proceso `Launch` suspendido | `SuspendedProcesses` no vacío | `aws autoscaling resume-processes --auto-scaling-group-name $ASG_NAME --scaling-processes Launch` |
| Cooldown activo | Status: `InProgress` en actividad | Esperar cooldown o reducirlo en la política |
| Alarma CW con datos insuficientes | `StateValue=INSUFFICIENT_DATA` | La métrica no tiene datos — verificar que las instancias tienen CW Agent o la métrica existe |
| Políticas deshabilitadas | `Enabled=false` | Habilitar la política |
| Instance Refresh en progreso | Actividad `Instance refresh in progress` | Esperar a que termine |
| Scheduled scaling override | Scheduled action sobrescribe desired | Revisar `describe-scheduled-actions` |

## Exam Trap
El **cooldown por defecto es 300 segundos (5 min)**. Durante el cooldown, el ASG ignora nuevas señales de scaling. Para Scale In, hay un `scale-in protection` adicional por instancia. Target Tracking tiene su propio cooldown independiente del de Step Scaling.
