# Lab v3 — Secrets, IAM y Observabilidad Profesional

## Objetivo

Añadir a la arquitectura v2 (ECS Fargate + ALB + Rolling Update) las capas de **seguridad** y **observabilidad** que se esperan en entornos productivos:

- Inyección de credenciales desde **Secrets Manager** (sin variables de entorno en texto plano)
- **Task Role** separado del Execution Role con principio de mínimo privilegio
- **Container Insights** para métricas avanzadas del cluster
- **CloudWatch Alarms** para latencia, errores y tareas unhealthy
- **Health checks en las 3 capas**: contenedor, ECS Task y ALB Target Group

Este lab cubre conceptos del examen **AWS Solutions Architect Associate** en los dominios:
- Diseño de arquitecturas seguras (IAM, Secrets Manager)
- Diseño de arquitecturas resilientes (health checks, alarms)
- Observabilidad y monitorización (Container Insights, CloudWatch)

---

## Arquitectura

```
Internet
    |
    v
[ALB internet-facing]  ←── Health check: HTTP /health cada 30s
    |
    |  (subnets privadas)
    v
[ECS Fargate Tasks x2]
    |  ↑
    |  └─── Container Health Check: CMD curl /health
    |
    ├──→ [Secrets Manager]  ←── Execution Role (GetSecretValue)
    |        shopapi/prod/db
    |        └── DB_HOST, DB_PASSWORD inyectados en el contenedor
    |
    ├──→ [DynamoDB: shopapi-products]  ←── Task Role (GetItem, Query, Scan)
    |
    └──→ [CloudWatch Logs]
              /ecs/shopapi-api

Observabilidad:
[Container Insights] → métricas avanzadas → [CloudWatch Alarms] → [SNS Topic]

IAM Roles:
┌─────────────────────────────────────────────────────────┐
│  Execution Role (shopapi-execution-role)                 │
│  - ecr:GetAuthorizationToken                            │
│  - ecr:BatchGetImage / ecr:GetDownloadUrlForLayer       │
│  - logs:CreateLogStream / PutLogEvents                  │
│  - secretsmanager:GetSecretValue  ← NUEVO               │
└─────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────┐
│  Task Role (shopapi-task-role)  ← NUEVO                 │
│  - dynamodb:GetItem                                     │
│  - dynamodb:Query                                       │
│  - dynamodb:Scan                                        │
│  (solo tabla shopapi-products)                          │
└─────────────────────────────────────────────────────────┘
```

### Diferencia clave: Execution Role vs Task Role

```
Arranque del contenedor:
  ECS Agent → usa Execution Role → descarga imagen ECR + obtiene secrets → lanza contenedor

Contenedor en ejecución:
  Código de la app → usa Task Role → llama a DynamoDB, S3, etc.
```

- **Execution Role**: lo usa el agente de ECS/Fargate, NO la aplicación. Necesita permisos para arrancar el contenedor (ECR, CloudWatch Logs, Secrets Manager).
- **Task Role**: lo usa la aplicación dentro del contenedor. Solo tiene los permisos que necesita la lógica de negocio.

---

## Prerrequisitos

- Lab v2 completado y funcionando:
  - Cluster `shopapi-cluster` (Fargate)
  - Service `shopapi-service` con 2 tareas corriendo
  - ALB respondiendo en `http://<alb-dns>/health`
  - Execution Role `shopapi-execution-role` creado
- AWS CLI configurado con permisos suficientes
- Variables de entorno:
  ```bash
  export AWS_REGION=eu-west-1
  export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  export CLUSTER_NAME=shopapi-cluster
  export SERVICE_NAME=shopapi-service
  ```

---

## Fase A: Manual (CLI)

### A1 — Secrets Manager

**Crear el secret con credenciales simuladas de base de datos:**

```bash
aws secretsmanager create-secret \
  --name "shopapi/prod/db" \
  --description "Credenciales de base de datos para ShopAPI en produccion" \
  --secret-string '{"host":"db.shopapi.internal","port":5432,"username":"shopapi_app","password":"changeme_en_prod"}' \
  --region eu-west-1
```

Salida esperada:
```json
{
    "ARN": "arn:aws:secretsmanager:eu-west-1:123456789012:secret:shopapi/prod/db-AbCdEf",
    "Name": "shopapi/prod/db",
    "VersionId": "a1b2c3d4-1234-5678-abcd-ef1234567890"
}
```

**Verificar el secret:**

```bash
aws secretsmanager get-secret-value \
  --secret-id "shopapi/prod/db" \
  --region eu-west-1 \
  --query 'SecretString' \
  --output text | python3 -m json.tool
```

Salida esperada:
```json
{
    "host": "db.shopapi.internal",
    "port": 5432,
    "username": "shopapi_app",
    "password": "changeme_en_prod"
}
```

**Concepto clave para el examen:** Secrets Manager rota automáticamente los secrets si configuras una Lambda de rotación. Cada vez que el contenedor arranca, el agente de ECS obtiene la versión actual del secret. Si rotas el secret, necesitas reiniciar las tareas para que obtengan el nuevo valor (o usar Parameter Store con `ssm:GetParameter` que sí permite referencias dinámicas).

---

### A2 — IAM: Task Role vs Execution Role

#### Crear el Task Role

Primero, crear el archivo de trust policy:

```bash
cat > /tmp/task-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
```

Crear el rol:

```bash
aws iam create-role \
  --role-name shopapi-task-role \
  --assume-role-policy-document file:///tmp/task-trust-policy.json \
  --description "Task Role para ShopAPI: permisos que usa la aplicacion en ejecucion"
```

Salida esperada:
```json
{
    "Role": {
        "RoleName": "shopapi-task-role",
        "RoleId": "AROA...",
        "Arn": "arn:aws:iam::123456789012:role/shopapi-task-role",
        "CreateDate": "2024-01-15T10:00:00+00:00",
        "AssumeRolePolicyDocument": { ... }
    }
}
```

#### Añadir policy inline para DynamoDB

```bash
aws iam put-role-policy \
  --role-name shopapi-task-role \
  --policy-name shopapi-dynamodb-products \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem"
        ],
        "Resource": [
          "arn:aws:dynamodb:eu-west-1:'"${ACCOUNT_ID}"':table/shopapi-products",
          "arn:aws:dynamodb:eu-west-1:'"${ACCOUNT_ID}"':table/shopapi-products/index/*"
        ]
      }
    ]
  }'
```

#### Actualizar el Execution Role con permiso para Secrets Manager

El Execution Role necesita poder leer el secret para inyectarlo al arrancar el contenedor:

```bash
# Obtener el ARN exacto del secret (incluye el sufijo aleatorio)
SECRET_ARN=$(aws secretsmanager describe-secret \
  --secret-id "shopapi/prod/db" \
  --query 'ARN' \
  --output text)

echo "Secret ARN: ${SECRET_ARN}"

# Añadir política inline al Execution Role
aws iam put-role-policy \
  --role-name shopapi-execution-role \
  --policy-name shopapi-secrets-access \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "secretsmanager:GetSecretValue"
        ],
        "Resource": "'"${SECRET_ARN}"'"
      }
    ]
  }'
```

**Importante:** Usar el ARN específico del secret (no `*`) es una buena práctica de seguridad. Si el secret usa una CMK (Customer Managed Key) en lugar de la clave AWS gestionada, también necesitas añadir `kms:Decrypt`.

---

### A3 — Container Insights

Habilitar Container Insights en el cluster:

```bash
aws ecs update-cluster-settings \
  --cluster shopapi-cluster \
  --settings name=containerInsights,value=enabled \
  --region eu-west-1
```

Salida esperada:
```json
{
    "cluster": {
        "clusterName": "shopapi-cluster",
        "settings": [
            {
                "name": "containerInsights",
                "value": "enabled"
            }
        ],
        "status": "ACTIVE"
    }
}
```

**Verificar que está habilitado:**

```bash
aws ecs describe-clusters \
  --clusters shopapi-cluster \
  --query 'clusters[0].settings' \
  --output table
```

**Métricas disponibles con Container Insights** (en CloudWatch bajo namespace `ECS/ContainerInsights`):

| Métrica | Descripción |
|---------|-------------|
| `CpuUtilized` | CPU usada por el servicio en vCPU |
| `CpuReserved` | CPU reservada (según Task Definition) |
| `MemoryUtilized` | Memoria usada en MB |
| `MemoryReserved` | Memoria reservada |
| `NetworkRxBytes` | Bytes recibidos por red |
| `NetworkTxBytes` | Bytes transmitidos por red |
| `RunningTaskCount` | Tareas en estado RUNNING |
| `PendingTaskCount` | Tareas en estado PENDING |
| `TaskCount` | Total de tareas del servicio |

**Explorar métricas en la consola:**
CloudWatch → Container Insights → ECS Services → shopapi-cluster

---

### A4 — CloudWatch Alarms

Primero, crear el SNS topic para recibir notificaciones:

```bash
# Crear el topic
SNS_TOPIC_ARN=$(aws sns create-topic \
  --name shopapi-alertas \
  --region eu-west-1 \
  --query 'TopicArn' \
  --output text)

echo "SNS Topic ARN: ${SNS_TOPIC_ARN}"

# Suscribirse con email (reemplaza con tu email)
aws sns subscribe \
  --topic-arn "${SNS_TOPIC_ARN}" \
  --protocol email \
  --notification-endpoint "tu-email@ejemplo.com" \
  --region eu-west-1
```

#### Alarma 1: Tasa de errores 5xx en ALB > 5%

```bash
# Obtener el nombre del Load Balancer (sufijo del ARN)
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names shopapi-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

# El nombre de dimensión es la parte del ARN después de "loadbalancer/"
ALB_DIMENSION=$(echo "${ALB_ARN}" | sed 's|.*loadbalancer/||')

echo "ALB Dimension: ${ALB_DIMENSION}"

aws cloudwatch put-metric-alarm \
  --alarm-name "shopapi-alb-5xx-rate" \
  --alarm-description "Tasa de errores HTTP 5xx del ALB supera el 5%" \
  --namespace "AWS/ApplicationELB" \
  --metric-name "HTTPCode_ELB_5XX_Count" \
  --dimensions Name=LoadBalancer,Value="${ALB_DIMENSION}" \
  --statistic Sum \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 5 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "${SNS_TOPIC_ARN}" \
  --ok-actions "${SNS_TOPIC_ARN}" \
  --region eu-west-1
```

**Nota sobre la tasa vs el conteo:** Esta alarma usa el conteo absoluto de errores 5xx. Para una alarma de tasa (porcentaje), necesitas una métrica calculada (Metric Math). Para el examen, es importante conocer ambas opciones.

#### Alarma 2: Latencia P99 del ALB > 1000ms

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "shopapi-alb-latencia-p99" \
  --alarm-description "Latencia P99 del ALB supera 1 segundo" \
  --namespace "AWS/ApplicationELB" \
  --metric-name "TargetResponseTime" \
  --dimensions Name=LoadBalancer,Value="${ALB_DIMENSION}" \
  --extended-statistic "p99" \
  --period 60 \
  --evaluation-periods 3 \
  --threshold 1.0 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "${SNS_TOPIC_ARN}" \
  --region eu-west-1
```

#### Alarma 3: Tareas en ejecución por debajo del desired count

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "shopapi-ecs-tareas-unhealthy" \
  --alarm-description "El numero de tareas en ejecucion es menor que el deseado (2)" \
  --namespace "ECS/ContainerInsights" \
  --metric-name "RunningTaskCount" \
  --dimensions \
    Name=ClusterName,Value=shopapi-cluster \
    Name=ServiceName,Value=shopapi-service \
  --statistic Average \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 2 \
  --comparison-operator LessThanThreshold \
  --treat-missing-data breaching \
  --alarm-actions "${SNS_TOPIC_ARN}" \
  --region eu-west-1
```

**Nota:** Esta alarma requiere Container Insights habilitado (namespace `ECS/ContainerInsights`). Sin Container Insights, `RunningTaskCount` no está disponible.

---

### A5 — Actualizar el Service con la nueva Task Definition

Ver el archivo `cli/03-task-def-secrets.json` para la Task Definition completa.

**Registrar la nueva revisión:**

```bash
NEW_TASK_DEF_ARN=$(aws ecs register-task-definition \
  --cli-input-json file://cli/03-task-def-secrets.json \
  --region eu-west-1 \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

echo "Nueva Task Definition: ${NEW_TASK_DEF_ARN}"
```

**Actualizar el servicio:**

```bash
aws ecs update-service \
  --cluster shopapi-cluster \
  --service shopapi-service \
  --task-definition "${NEW_TASK_DEF_ARN}" \
  --region eu-west-1
```

---

## Task Definition con Secrets y Task Role

### Archivo: `cli/03-task-def-secrets.json`

La parte clave de la Task Definition actualizada:

```json
{
  "family": "shopapi-api",
  "taskRoleArn": "arn:aws:iam::ACCOUNT_ID:role/shopapi-task-role",
  "executionRoleArn": "arn:aws:iam::ACCOUNT_ID:role/shopapi-execution-role",
  "containerDefinitions": [
    {
      "name": "shopapi-api",
      "image": "ACCOUNT_ID.dkr.ecr.eu-west-1.amazonaws.com/shopapi/api:latest",
      "portMappings": [{"containerPort": 8080, "protocol": "tcp"}],
      "environment": [
        {"name": "ENV", "value": "production"},
        {"name": "PORT", "value": "8080"}
      ],
      "secrets": [
        {
          "name": "DB_HOST",
          "valueFrom": "arn:aws:secretsmanager:eu-west-1:ACCOUNT_ID:secret:shopapi/prod/db:host::"
        },
        {
          "name": "DB_PASSWORD",
          "valueFrom": "arn:aws:secretsmanager:eu-west-1:ACCOUNT_ID:secret:shopapi/prod/db:password::"
        }
      ],
      "healthCheck": {
        "command": ["CMD", "curl", "-f", "http://localhost:8080/health"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 30
      }
    }
  ]
}
```

### Anatomía del campo `valueFrom`

El formato del `valueFrom` para Secrets Manager es:

```
arn:aws:secretsmanager:REGION:ACCOUNT_ID:secret:NOMBRE_SECRET:CLAVE_JSON:STAGE:VERSION
```

| Parte | Ejemplo | Descripción |
|-------|---------|-------------|
| `arn:aws:secretsmanager` | fijo | Servicio |
| `eu-west-1` | región | Región del secret |
| `ACCOUNT_ID` | `123456789012` | ID de la cuenta |
| `secret:shopapi/prod/db` | nombre | Nombre del secret (con prefijo `secret:`) |
| `-AbCdEf` | sufijo | AWS añade 6 caracteres al nombre físico |
| `host` | clave JSON | La clave dentro del JSON del secret |
| `::`  | vacío | Stage (AWSCURRENT) y Version (última) |

**Ejemplos de referencias:**

```
# Clave específica del JSON (más seguro: solo expones lo necesario)
arn:aws:secretsmanager:eu-west-1:123456789012:secret:shopapi/prod/db:password::

# Secret completo como string (si el secret es un string, no JSON)
arn:aws:secretsmanager:eu-west-1:123456789012:secret:shopapi/prod/db::::

# Versión específica
arn:aws:secretsmanager:eu-west-1:123456789012:secret:shopapi/prod/db:password:AWSPREVIOUS:
```

---

## Health Checks: Las 3 capas

### Capa 1: Container Health Check (Docker / ECS)

Definido en la Task Definition:

```json
"healthCheck": {
  "command": ["CMD", "curl", "-f", "http://localhost:8080/health"],
  "interval": 30,
  "timeout": 5,
  "retries": 3,
  "startPeriod": 30
}
```

- `interval`: Cada cuántos segundos se ejecuta el check
- `timeout`: Tiempo máximo de respuesta antes de considerar fallo
- `retries`: Fallos consecutivos antes de marcar el contenedor como UNHEALTHY
- `startPeriod`: Tiempo inicial en el que los fallos no cuentan (la app está arrancando)
- Si el contenedor queda UNHEALTHY, ECS lo considera unhealthy y lo reemplaza

### Capa 2: ECS Task Health (Service Scheduler)

El ECS Service Scheduler monitoriza el estado de las tareas. Si una tarea está UNHEALTHY:
1. La marca para reemplazo
2. Lanza una nueva tarea
3. Espera a que la nueva esté HEALTHY
4. Termina la tarea antigua

Parámetro clave del Service:
```bash
--health-check-grace-period-seconds 60
```
Tiempo que ECS espera antes de empezar a evaluar el health check de las nuevas tareas. Demasiado bajo → reinicio prematuro. Demasiado alto → tiempo de detección de fallos aumenta.

### Capa 3: ALB Target Health Check

Definido en el Target Group:

```bash
aws elbv2 modify-target-group \
  --target-group-arn "${TG_ARN}" \
  --health-check-path "/health" \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3
```

- El ALB sondea directamente el contenedor (no a través de otro contenedor)
- Si un target falla, el ALB deja de enviarle tráfico pero ECS puede seguir ejecutándolo
- Los 3 health checks son independientes pero complementarios

---

## Validación

### 1. Verificar que el secret se inyecta correctamente

```bash
# Obtener el ARN de una tarea en ejecución
TASK_ARN=$(aws ecs list-tasks \
  --cluster shopapi-cluster \
  --service-name shopapi-service \
  --desired-status RUNNING \
  --query 'taskArns[0]' \
  --output text)

# Ver los detalles de la tarea (secrets no aparecen en texto plano, solo como nombre)
aws ecs describe-tasks \
  --cluster shopapi-cluster \
  --tasks "${TASK_ARN}" \
  --query 'tasks[0].containers[0].{status:lastStatus,health:healthStatus,env:environmentFiles}' \
  --output json
```

**Nota de seguridad:** Los valores de los secrets NO aparecen en `describe-tasks`. Solo se muestra el nombre de la variable de entorno. Esto es por diseño.

### 2. Verificar Container Insights activo

```bash
aws ecs describe-clusters \
  --clusters shopapi-cluster \
  --query 'clusters[0].settings[?name==`containerInsights`]'
```

Salida esperada:
```json
[{"name": "containerInsights", "value": "enabled"}]
```

### 3. Verificar las alarmas creadas

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix "shopapi-" \
  --query 'MetricAlarms[*].{Nombre:AlarmName,Estado:StateValue,Metrica:MetricName}' \
  --output table
```

Salida esperada:
```
-----------------------------------------------------------------------
| Nombre                       | Estado       | Metrica              |
|------------------------------|--------------|----------------------|
| shopapi-alb-5xx-rate         | OK           | HTTPCode_ELB_5XX_Count|
| shopapi-alb-latencia-p99     | OK           | TargetResponseTime   |
| shopapi-ecs-tareas-unhealthy | OK           | RunningTaskCount     |
-----------------------------------------------------------------------
```

### 4. Verificar el Task Role asignado

```bash
aws ecs describe-task-definition \
  --task-definition shopapi-api \
  --query 'taskDefinition.{taskRoleArn:taskRoleArn,executionRoleArn:executionRoleArn,revision:revision}'
```

---

## Troubleshooting

Ver los archivos en la carpeta `troubleshooting/`:

- `01-health-check-failure.md` — Tareas reiniciándose en loop
- `02-secret-injection-failure.md` — AccessDeniedException al obtener secrets
- `03-container-insights-costs.md` — Costes inesperados de Container Insights

---

## Limpieza

Ejecutar en orden para evitar dependencias:

```bash
# 1. Eliminar alarmas
aws cloudwatch delete-alarms \
  --alarm-names shopapi-alb-5xx-rate shopapi-alb-latencia-p99 shopapi-ecs-tareas-unhealthy \
  --region eu-west-1

# 2. Eliminar SNS topic
aws sns delete-topic \
  --topic-arn "${SNS_TOPIC_ARN}" \
  --region eu-west-1

# 3. Deshabilitar Container Insights
aws ecs update-cluster-settings \
  --cluster shopapi-cluster \
  --settings name=containerInsights,value=disabled \
  --region eu-west-1

# 4. Eliminar Task Role y sus políticas
aws iam delete-role-policy \
  --role-name shopapi-task-role \
  --policy-name shopapi-dynamodb-products

aws iam delete-role \
  --role-name shopapi-task-role

# 5. Eliminar política inline del Execution Role
aws iam delete-role-policy \
  --role-name shopapi-execution-role \
  --policy-name shopapi-secrets-access

# 6. Eliminar el secret (con un periodo de recuperación de 7 días)
aws secretsmanager delete-secret \
  --secret-id "shopapi/prod/db" \
  --recovery-window-in-days 7 \
  --region eu-west-1

# Para eliminar inmediatamente (sin periodo de recuperación):
# aws secretsmanager delete-secret \
#   --secret-id "shopapi/prod/db" \
#   --force-delete-without-recovery \
#   --region eu-west-1
```

Ver el script completo en `cli/99-cleanup.sh`.

---

## Conceptos clave para el examen SAA

| Concepto | Detalle |
|----------|---------|
| Secrets Manager vs Parameter Store | Secrets Manager: rotación automática, coste por secret/mes. Parameter Store SecureString: sin coste extra (standard tier), sin rotación automática. |
| Execution Role vs Task Role | Execution Role: agente ECS (arranque). Task Role: aplicación (en ejecución). |
| Container Insights | Métricas custom en CloudWatch → coste adicional. Namespace: `ECS/ContainerInsights`. |
| `startPeriod` en healthCheck | Tiempo de gracia para que la app arranque antes de contar fallos. Crítico para apps lentas en arrancar. |
| `health-check-grace-period-seconds` | Parámetro del Service (no de la Task Definition). Distinto al `startPeriod` del container healthcheck. |
| `valueFrom` en secrets | Formato ARN específico de Secrets Manager con sufijo de clave JSON. |
