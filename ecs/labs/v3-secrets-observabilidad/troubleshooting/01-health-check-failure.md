# Troubleshooting 01 — Tareas reiniciándose en loop después del deploy

## Escenario

Acabas de desplegar la nueva Task Definition v3 con secrets. En la consola de ECS ves que las tareas arrancan, pasan a estado RUNNING brevemente, y luego vuelven a STOPPED. El ciclo se repite indefinidamente. El servicio nunca llega a `runningCount = desiredCount`.

---

## Síntomas observables

### En la consola AWS

- En el Service, la pestaña "Events" muestra mensajes como:
  ```
  service shopapi-service (port 8080) is unhealthy in target-group shopapi-tg due to (reason Health checks failed)
  service shopapi-service has stopped 1 running tasks: task abc123
  ```
- La columna "Running tasks" oscila entre 0 y 1 (nunca llega a 2)
- En la pestaña "Deployments", el deployment lleva muchos minutos en estado "In progress"

### En la CLI

```bash
# Ver los eventos del service
aws ecs describe-services \
  --cluster shopapi-cluster \
  --services shopapi-service \
  --region eu-west-1 \
  --query 'services[0].events[:10]' \
  --output table
```

Salida típica de un health check en loop:
```
---------------------------------------------------------------------
| message                                                           |
|-------------------------------------------------------------------|
| service shopapi-service: task abc123 is unhealthy                |
| service shopapi-service: task abc123 has stopped                 |
| service shopapi-service: starting task def456                    |
| service shopapi-service: task def456 is unhealthy                |
| ...                                                               |
---------------------------------------------------------------------
```

---

## Comandos de diagnóstico

### Paso 1: Ver la razón por la que se paró la tarea

```bash
# Primero, obtener ARNs de tareas paradas (stopped)
STOPPED_TASK_ARNS=$(aws ecs list-tasks \
  --cluster shopapi-cluster \
  --service-name shopapi-service \
  --desired-status STOPPED \
  --region eu-west-1 \
  --query 'taskArns[:3]' \
  --output text)

echo "Tareas paradas encontradas: ${STOPPED_TASK_ARNS}"

# Ver razón de parada (stopCode y stoppedReason son los más informativos)
aws ecs describe-tasks \
  --cluster shopapi-cluster \
  --tasks ${STOPPED_TASK_ARNS} \
  --region eu-west-1 \
  --query 'tasks[0].{
    stopCode:stopCode,
    reason:stoppedReason,
    container:{
      health:containers[0].healthStatus,
      reason:containers[0].reason,
      exitCode:containers[0].exitCode
    }
  }' \
  --output json
```

Posibles valores de `stopCode` y su significado:

| stopCode | Significado |
|----------|-------------|
| `TaskFailedToStart` | El contenedor falló antes de arrancar (error de pull de imagen, secreto no encontrado) |
| `EssentialContainerExited` | El contenedor essential terminó (exitCode != 0 indica error de la app) |
| `ServiceSchedulerInitiated` | ECS paró la tarea por health check fallido |
| `UserInitiated` | Parada manual |

### Paso 2: Ver el estado del health check del contenedor

```bash
# Ver el health status del contenedor en una tarea en ejecución
RUNNING_TASK=$(aws ecs list-tasks \
  --cluster shopapi-cluster \
  --service-name shopapi-service \
  --desired-status RUNNING \
  --region eu-west-1 \
  --query 'taskArns[0]' \
  --output text)

aws ecs describe-tasks \
  --cluster shopapi-cluster \
  --tasks "${RUNNING_TASK}" \
  --region eu-west-1 \
  --query 'tasks[0].containers[0].{
    nombre:name,
    estado:lastStatus,
    healthStatus:healthStatus,
    exitCode:exitCode,
    reason:reason
  }' \
  --output json
```

Valores de `healthStatus`:
- `HEALTHY` — el contenedor pasa el health check
- `UNHEALTHY` — el contenedor falla el health check (será reemplazado)
- `UNKNOWN` — aún en el periodo de gracia (`startPeriod`)

### Paso 3: Ver los logs del contenedor

```bash
# Ver los últimos logs de la tarea
aws logs tail /ecs/shopapi-api \
  --since 10m \
  --follow \
  --region eu-west-1
```

### Paso 4: Ver el health del Target Group en el ALB

```bash
TG_ARN=$(aws elbv2 describe-target-groups \
  --query 'TargetGroups[?TargetGroupName==`shopapi-tg`].TargetGroupArn' \
  --output text \
  --region eu-west-1)

aws elbv2 describe-target-health \
  --target-group-arn "${TG_ARN}" \
  --region eu-west-1 \
  --query 'TargetHealthDescriptions[*].{
    Target:Target.Id,
    Estado:TargetHealth.State,
    Razon:TargetHealth.Reason,
    Descripcion:TargetHealth.Description
  }' \
  --output table
```

---

## Causas posibles y soluciones

### Causa 1 (Probabilidad: Alta) — startPeriod demasiado corto

**Síntoma específico:**
- `healthStatus: UNHEALTHY` en los primeros 30 segundos
- Los logs muestran que la app está arrancando normalmente
- El contenedor se mata antes de que la app esté lista

**Por qué ocurre:**
El `startPeriod` de 30 segundos puede ser insuficiente si la app tarda más en arrancar. En FastAPI con dependencias pesadas o cold starts, el tiempo de arranque puede ser de 45-60 segundos. Si el health check falla durante el startPeriod, los fallos no cuentan. Pero si se supera el startPeriod y la app aún no responde, el contenedor pasa a UNHEALTHY.

**Diagnóstico:**
```bash
# Ver los timestamps de los logs para estimar el tiempo de arranque
aws logs filter-log-events \
  --log-group-name /ecs/shopapi-api \
  --filter-pattern "Application startup" \
  --region eu-west-1 \
  --query 'events[*].{timestamp:timestamp,mensaje:message}' \
  --output table
```

**Solución:**

Aumentar el `startPeriod` en la Task Definition:

```json
"healthCheck": {
  "command": ["CMD", "curl", "-f", "http://localhost:8080/health"],
  "interval": 30,
  "timeout": 5,
  "retries": 3,
  "startPeriod": 60
}
```

Registra una nueva revisión de la Task Definition y actualiza el Service.

**Prevención:**
Mide el tiempo de arranque real de tu aplicación antes de configurar `startPeriod`. Un valor seguro es el tiempo de arranque real + 30 segundos de margen.

---

### Causa 2 (Probabilidad: Alta) — El endpoint /health no existe o devuelve error

**Síntoma específico:**
- `stoppedReason: "Task failed ELB health checks"`
- En los logs: `curl: (22) The requested URL returned error: 404` o `500 Internal Server Error`
- El health check del ALB muestra `unhealthy` con descripción `Target returned HTTP 404`

**Por qué ocurre:**
El health check hace `curl -f http://localhost:8080/health`. Si la aplicación:
1. No tiene una ruta `/health` definida → 404 (curl falla con `-f`)
2. La ruta existe pero lanza una excepción → 500

**Diagnóstico:**

```bash
# Verificar qué responde el endpoint desde dentro (si tienes ECS Exec)
# Esto requiere enableExecuteCommand en el service y SSM Agent en la imagen

# Alternativa: Ver los logs de acceso de la app
aws logs filter-log-events \
  --log-group-name /ecs/shopapi-api \
  --filter-pattern "GET /health" \
  --region eu-west-1 \
  --query 'events[*].message' \
  --output text

# Ver el status del target en el ALB (muestra el código HTTP)
aws elbv2 describe-target-health \
  --target-group-arn "${TG_ARN}" \
  --region eu-west-1 \
  --query 'TargetHealthDescriptions[*].TargetHealth' \
  --output json
```

**Solución:**

Asegúrate de que tu aplicación FastAPI tiene el endpoint `/health`:

```python
# En main.py de FastAPI
from fastapi import FastAPI

app = FastAPI()

@app.get("/health")
async def health():
    return {"status": "healthy"}
```

Si el endpoint existe pero devuelve 500, revisa los logs para identificar la excepción:

```bash
aws logs filter-log-events \
  --log-group-name /ecs/shopapi-api \
  --filter-pattern "ERROR" \
  --start-time $(date -d '10 minutes ago' +%s000) \
  --region eu-west-1 \
  --query 'events[*].message' \
  --output text
```

**Prevención:**
Incluye el endpoint `/health` en los tests de integración del pipeline CI/CD. Que falle el pipeline antes de llegar a ECS.

---

### Causa 3 (Probabilidad: Media) — healthCheckGracePeriodSeconds muy bajo en el Service

**Síntoma específico:**
- Las tareas son matadas en los primeros segundos después de arrancar
- El `healthStatus` del contenedor muestra `UNKNOWN` (no ha dado tiempo a evaluarse)
- El ALB marca el target como unhealthy antes de que la app esté lista

**La diferencia clave entre `startPeriod` y `healthCheckGracePeriodSeconds`:**

```
startPeriod (Task Definition):
  └── Le dice a ECS que ignore los fallos del CONTAINER health check
      durante X segundos desde que el contenedor arranca.
      Solo afecta al health check del contenedor (CMD).

healthCheckGracePeriodSeconds (Service):
  └── Le dice al ECS Service Scheduler que ignore las señales de
      unhealthy del ALB Target Group durante X segundos desde que
      la tarea entra en RUNNING.
      Solo afecta al health check del ALB.
```

**Diagnóstico:**

```bash
aws ecs describe-services \
  --cluster shopapi-cluster \
  --services shopapi-service \
  --region eu-west-1 \
  --query 'services[0].{
    healthCheckGracePeriodSeconds:healthCheckGracePeriodSeconds,
    runningCount:runningCount,
    desiredCount:desiredCount
  }' \
  --output json
```

**Solución:**

Aumentar `healthCheckGracePeriodSeconds` al actualizar el service:

```bash
aws ecs update-service \
  --cluster shopapi-cluster \
  --service shopapi-service \
  --health-check-grace-period-seconds 120 \
  --region eu-west-1
```

**Valor recomendado:** Al menos el doble del tiempo de arranque de la aplicación.

---

## Tabla resumen de diagnóstico

| stopCode / síntoma | Causa probable | Solución |
|---|---|---|
| healthStatus: UNHEALTHY en < 30s | startPeriod muy corto | Aumentar startPeriod en Task Definition |
| ALB: "Target returned HTTP 404" | Endpoint /health no existe | Añadir ruta /health a la app |
| ALB: "Target returned HTTP 500" | Excepción en /health | Revisar logs, corregir el endpoint |
| Tarea muerta antes de 60s, UNKNOWN health | healthCheckGracePeriodSeconds bajo | Aumentar en el Service |
| exitCode: 1 o similar | La app arranca y falla | Revisar logs de la app |

---

## Cómo prevenirlo

1. **Testea el endpoint `/health` localmente** antes de hacer deploy:
   ```bash
   docker run -p 8080:8080 TU_IMAGEN
   curl http://localhost:8080/health
   ```

2. **Configura `startPeriod` con margen generoso** (tiempo real de arranque + 30s).

3. **Usa `healthCheckGracePeriodSeconds`** en el Service para aplicaciones lentas en arrancar.

4. **Monitorea el primer deploy** activamente: `aws ecs describe-services` cada 15 segundos durante el deployment.

5. **Configura la alarma de tareas unhealthy** (como hicimos en el Lab v3) para detectar el problema antes de que el on-call lo descubra.
