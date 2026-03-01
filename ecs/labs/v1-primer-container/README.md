# Lab v1 — Primer Container en ECS Fargate

## Objetivo

Desplegar por primera vez una aplicación containerizada (ShopAPI) en Amazon ECS usando el
launch type **Fargate**. Al finalizar este lab comprenderás el ciclo completo:
imagen Docker → ECR → Task Definition → ECS Task ejecutándose.

### Qué aprenderás

- Crear y gestionar un repositorio ECR
- Autenticar Docker con ECR y hacer push de una imagen
- Crear un cluster ECS con Fargate
- Registrar una Task Definition (familia, CPU, memoria, red, logs)
- Ejecutar un RunTask manualmente y monitorizar su estado
- Consultar logs de contenedores en CloudWatch Logs

---

## Arquitectura del Lab

```
┌─────────────────────────────────────────────────────────────────────┐
│  AWS (eu-west-1)                                                     │
│                                                                      │
│  ┌──────────────┐    push     ┌──────────────────────────────────┐  │
│  │  Docker CLI  │ ──────────► │  ECR: shopapi/api                │  │
│  │  (local)     │             │  ACCOUNT_ID.dkr.ecr.eu-west-1... │  │
│  └──────────────┘             └──────────────┬───────────────────┘  │
│                                              │ pull                  │
│                                              ▼                       │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  ECS Cluster: shopapi-cluster                                  │  │
│  │                                                                │  │
│  │  ┌─────────────────────────────────────────────────────────┐  │  │
│  │  │  Task (Fargate)  — family: shopapi-api                   │  │  │
│  │  │                                                          │  │  │
│  │  │  ┌──────────────────────────────────────────────────┐   │  │  │
│  │  │  │  Container: shopapi-api                           │   │  │  │
│  │  │  │  Imagen: shopapi/api:latest                       │   │  │  │
│  │  │  │  Puerto: 8080                                     │   │  │  │
│  │  │  │  CPU: 256 | Mem: 512 MB                           │   │  │  │
│  │  │  └──────────────────────┬───────────────────────────┘   │  │  │
│  │  └─────────────────────────┼───────────────────────────────┘  │  │
│  └─────────────────────────────┼───────────────────────────────────┘  │
│                                │ logs (awslogs)                    │
│                                ▼                                    │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  CloudWatch Logs: /ecs/shopapi                                 │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  IAM: ecsTaskExecutionRole ──► AmazonECSTaskExecutionRolePolicy      │
└─────────────────────────────────────────────────────────────────────┘
```

**Flujo de datos**:
1. Build de la imagen en local → Push a ECR
2. ECS Task Definition referencia la imagen de ECR
3. Al ejecutar RunTask, Fargate descarga la imagen y arranca el contenedor
4. Los logs del contenedor se envían a CloudWatch Logs

---

## Prerrequisitos

### Herramientas necesarias

```bash
# Verificar versiones mínimas requeridas
aws --version      # >= 2.0
docker --version   # >= 20.0
jq --version       # >= 1.6 (para parsear JSON)
terraform --version # >= 1.5 (solo para Fase B)
```

### Variables de entorno

Exportar antes de empezar. Estas variables se usan en todos los comandos del lab:

```bash
# Cuenta y región
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION="eu-west-1"

# Prefijo del proyecto
export PROJECT_PREFIX="shopapi"

# Repositorio ECR
export ECR_REPO_NAME="shopapi/api"
export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export ECR_REPO_URI="${ECR_REGISTRY}/${ECR_REPO_NAME}"
export IMAGE_TAG="0.1.0"

# Cluster y task
export CLUSTER_NAME="shopapi-cluster"
export TASK_FAMILY="shopapi-api"

# Ruta al código de la aplicación (ajustar a tu ruta local)
export APP_DIR="/home/sergi/DevOpsProjects/aws/services/shopapi"

# Verificar que las variables se cargaron correctamente
echo "Account ID : ${AWS_ACCOUNT_ID}"
echo "Region     : ${AWS_REGION}"
echo "ECR URI    : ${ECR_REPO_URI}"
echo "Cluster    : ${CLUSTER_NAME}"
```

### Permisos IAM necesarios

El usuario/rol de AWS CLI debe tener permisos para:
- ECR: `ecr:CreateRepository`, `ecr:GetAuthorizationToken`, `ecr:BatchCheckLayerAvailability`, `ecr:PutImage`
- ECS: `ecs:CreateCluster`, `ecs:RegisterTaskDefinition`, `ecs:RunTask`
- IAM: `iam:CreateRole`, `iam:AttachRolePolicy`
- CloudWatch Logs: `logs:CreateLogGroup`

---

## Fase A: Manual (Consola + CLI)

### A1: Consola AWS

Esta sección describe los pasos equivalentes en la Consola Web de AWS.
Útil para entender visualmente cada servicio.

#### A1.1 — Crear repositorio ECR

1. Ir a **Amazon ECR** → **Repositories** → **Create repository**
2. Configuración:
   - **Visibility**: Private
   - **Repository name**: `shopapi/api`
   - **Tag immutability**: Disabled (MUTABLE para este lab)
   - **Image scan on push**: Enabled
3. Clic en **Create repository**
4. Copiar el **Repository URI** que aparece (formato: `ACCOUNT_ID.dkr.ecr.eu-west-1.amazonaws.com/shopapi/api`)

#### A1.2 — Crear cluster ECS

1. Ir a **Amazon ECS** → **Clusters** → **Create Cluster**
2. Configuración:
   - **Cluster name**: `shopapi-cluster`
   - **Infrastructure**: Seleccionar solo **AWS Fargate (serverless)**
   - **Monitoring**: Activar **Use Container Insights**
3. Clic en **Create**
4. Esperar a que el estado cambie a **ACTIVE**

#### A1.3 — Registrar Task Definition

1. Ir a **Amazon ECS** → **Task definitions** → **Create new task definition**
2. Configuración principal:
   - **Family**: `shopapi-api`
   - **Launch type**: AWS Fargate
   - **Operating system/Architecture**: Linux/X86_64
   - **Task CPU**: 0.25 vCPU (256)
   - **Task memory**: 0.5 GB (512 MB)
   - **Task execution role**: Crear nuevo rol o seleccionar `shopapi-execution-role`
3. Configuración del contenedor (clic en **Add container**):
   - **Container name**: `shopapi-api`
   - **Image URI**: `ACCOUNT_ID.dkr.ecr.eu-west-1.amazonaws.com/shopapi/api:0.1.0`
   - **Container port**: 8080, Protocol: TCP
   - En **Environment variables** añadir:
     - `APP_ENV` = `production`
     - `APP_VERSION` = `0.1.0`
   - En **Logging**: Seleccionar **awslogs**
     - Log group: `/ecs/shopapi`
     - Region: `eu-west-1`
     - Stream prefix: `shopapi-api`
4. Clic en **Create**

#### A1.4 — Ejecutar RunTask desde la consola

1. Ir al cluster **shopapi-cluster** → pestaña **Tasks** → **Run new task**
2. Configuración:
   - **Launch type**: Fargate
   - **Task definition**: `shopapi-api` (latest revision)
   - **Cluster**: `shopapi-cluster`
3. **Networking**:
   - **VPC**: Seleccionar tu VPC (por defecto si no tienes otra)
   - **Subnets**: Seleccionar una subnet pública
   - **Security groups**: Uno que permita tráfico en puerto 8080
   - **Auto-assign public IP**: ENABLED
4. Clic en **Run task**
5. Ver el estado del task: PROVISIONING → PENDING → RUNNING

#### A1.5 — Ver logs en CloudWatch

1. Ir a **CloudWatch** → **Log groups** → `/ecs/shopapi`
2. Entrar en el log stream del contenedor (formato: `shopapi-api/shopapi-api/TASK_ID`)
3. Verificar que aparecen los logs de arranque de FastAPI

---

### A2: AWS CLI

#### A2.1 — Crear repositorio ECR

```bash
# Crear repositorio ECR con escaneo de imagen habilitado
aws ecr create-repository \
  --repository-name shopapi/api \
  --region eu-west-1 \
  --image-scanning-configuration scanOnPush=true \
  --image-tag-mutability MUTABLE

# Resultado esperado:
# {
#   "repository": {
#     "repositoryArn": "arn:aws:ecr:eu-west-1:123456789012:repository/shopapi/api",
#     "registryId": "123456789012",
#     "repositoryName": "shopapi/api",
#     "repositoryUri": "123456789012.dkr.ecr.eu-west-1.amazonaws.com/shopapi/api",
#     "createdAt": "2024-01-15T10:00:00+00:00",
#     "imageTagMutability": "MUTABLE",
#     "imageScanningConfiguration": {
#       "scanOnPush": true
#     }
#   }
# }

# Verificar que el repositorio existe
aws ecr describe-repositories \
  --repository-names shopapi/api \
  --region eu-west-1 \
  --query 'repositories[0].repositoryUri' \
  --output text

# Resultado esperado:
# 123456789012.dkr.ecr.eu-west-1.amazonaws.com/shopapi/api
```

#### A2.2 — Autenticar Docker con ECR

```bash
# Obtener token de autenticación y hacer login en Docker
aws ecr get-login-password \
  --region eu-west-1 \
  | docker login \
    --username AWS \
    --password-stdin \
    ${AWS_ACCOUNT_ID}.dkr.ecr.eu-west-1.amazonaws.com

# Resultado esperado:
# Login Succeeded
```

#### A2.3 — Build, tag y push de la imagen

```bash
# Ir al directorio de la aplicación
cd ${APP_DIR}

# Verificar que existe el Dockerfile
ls -la Dockerfile

# Build de la imagen con tag de versión
docker build \
  --tag shopapi-api:0.1.0 \
  --tag shopapi-api:latest \
  --file Dockerfile \
  .

# Resultado esperado (últimas líneas):
# Successfully built a1b2c3d4e5f6
# Successfully tagged shopapi-api:0.1.0
# Successfully tagged shopapi-api:latest

# Verificar la imagen creada
docker images shopapi-api

# Resultado esperado:
# REPOSITORY    TAG       IMAGE ID       CREATED          SIZE
# shopapi-api   0.1.0     a1b2c3d4e5f6   10 seconds ago   180MB
# shopapi-api   latest    a1b2c3d4e5f6   10 seconds ago   180MB

# Taggear para ECR (añadir el registry URI como prefijo)
docker tag shopapi-api:0.1.0 \
  ${AWS_ACCOUNT_ID}.dkr.ecr.eu-west-1.amazonaws.com/shopapi/api:0.1.0

docker tag shopapi-api:latest \
  ${AWS_ACCOUNT_ID}.dkr.ecr.eu-west-1.amazonaws.com/shopapi/api:latest

# Push a ECR
docker push \
  ${AWS_ACCOUNT_ID}.dkr.ecr.eu-west-1.amazonaws.com/shopapi/api:0.1.0

docker push \
  ${AWS_ACCOUNT_ID}.dkr.ecr.eu-west-1.amazonaws.com/shopapi/api:latest

# Resultado esperado (por cada push):
# The push refers to repository [123456789012.dkr.ecr.eu-west-1.amazonaws.com/shopapi/api]
# 0.1.0: digest: sha256:abc123... size: 1234

# Verificar que la imagen está en ECR
aws ecr list-images \
  --repository-name shopapi/api \
  --region eu-west-1

# Resultado esperado:
# {
#   "imageIds": [
#     { "imageDigest": "sha256:abc123...", "imageTag": "0.1.0" },
#     { "imageDigest": "sha256:abc123...", "imageTag": "latest" }
#   ]
# }
```

#### A2.4 — Crear cluster ECS

```bash
# Crear cluster ECS (Fargate — no requiere instancias EC2)
aws ecs create-cluster \
  --cluster-name shopapi-cluster \
  --region eu-west-1 \
  --settings name=containerInsights,value=enabled \
  --tags key=Project,value=shopapi key=Lab,value=v1

# Resultado esperado:
# {
#   "cluster": {
#     "clusterArn": "arn:aws:ecs:eu-west-1:123456789012:cluster/shopapi-cluster",
#     "clusterName": "shopapi-cluster",
#     "status": "ACTIVE",
#     "settings": [
#       { "name": "containerInsights", "value": "enabled" }
#     ]
#   }
# }

# Verificar estado del cluster
aws ecs describe-clusters \
  --clusters shopapi-cluster \
  --region eu-west-1 \
  --query 'clusters[0].{Nombre:clusterName, Estado:status}'

# Resultado esperado:
# {
#   "Nombre": "shopapi-cluster",
#   "Estado": "ACTIVE"
# }
```

#### A2.5 — Crear IAM Execution Role

```bash
# Crear la trust policy para que ECS pueda asumir el rol
cat > /tmp/ecs-trust-policy.json << 'EOF'
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

# Crear el IAM Role
aws iam create-role \
  --role-name shopapi-execution-role \
  --assume-role-policy-document file:///tmp/ecs-trust-policy.json \
  --description "Rol de ejecucion para ECS Fargate del proyecto ShopAPI"

# Resultado esperado:
# {
#   "Role": {
#     "RoleName": "shopapi-execution-role",
#     "Arn": "arn:aws:iam::123456789012:role/shopapi-execution-role",
#     "AssumeRolePolicyDocument": { ... }
#   }
# }

# Adjuntar la política gestionada por AWS para ECS
# Esta política permite: pull de ECR + enviar logs a CloudWatch
aws iam attach-role-policy \
  --role-name shopapi-execution-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

# Verificar que la política se adjuntó
aws iam list-attached-role-policies \
  --role-name shopapi-execution-role

# Resultado esperado:
# {
#   "AttachedPolicies": [
#     {
#       "PolicyName": "AmazonECSTaskExecutionRolePolicy",
#       "PolicyArn": "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
#     }
#   ]
# }

# Guardar el ARN del rol en una variable
export EXECUTION_ROLE_ARN=$(aws iam get-role \
  --role-name shopapi-execution-role \
  --query 'Role.Arn' \
  --output text)

echo "Execution Role ARN: ${EXECUTION_ROLE_ARN}"
```

#### A2.6 — Crear CloudWatch Log Group

```bash
# Crear el log group para los logs del contenedor
aws logs create-log-group \
  --log-group-name /ecs/shopapi \
  --region eu-west-1

# Establecer retención de logs a 30 días (para no incurrir en costes excesivos)
aws logs put-retention-policy \
  --log-group-name /ecs/shopapi \
  --retention-in-days 30 \
  --region eu-west-1

# Verificar el log group
aws logs describe-log-groups \
  --log-group-name-prefix /ecs/shopapi \
  --region eu-west-1 \
  --query 'logGroups[0].{Nombre:logGroupName, Retencion:retentionInDays}'

# Resultado esperado:
# {
#   "Nombre": "/ecs/shopapi",
#   "Retencion": 30
# }
```

#### A2.7 — Registrar Task Definition

La Task Definition define QUÉ ejecutar y CON QUÉ recursos. Ver el archivo completo
en `cli/task-definition.json`.

```bash
# Antes de registrar, sustituir ACCOUNT_ID con el valor real
# (el archivo task-definition.json usa el placeholder ACCOUNT_ID)
TASK_DEF_FILE="cli/task-definition.json"

# Sustituir el placeholder y guardar en un archivo temporal
sed "s/ACCOUNT_ID/${AWS_ACCOUNT_ID}/g" ${TASK_DEF_FILE} > /tmp/task-definition-resolved.json

# Registrar la Task Definition en ECS
aws ecs register-task-definition \
  --cli-input-json file:///tmp/task-definition-resolved.json \
  --region eu-west-1

# Resultado esperado:
# {
#   "taskDefinition": {
#     "taskDefinitionArn": "arn:aws:ecs:eu-west-1:123456789012:task-definition/shopapi-api:1",
#     "family": "shopapi-api",
#     "revision": 1,
#     "status": "ACTIVE",
#     "requiresCompatibilities": ["FARGATE"],
#     "cpu": "256",
#     "memory": "512"
#   }
# }

# Verificar que la task definition está activa
aws ecs describe-task-definition \
  --task-definition shopapi-api \
  --region eu-west-1 \
  --query 'taskDefinition.{Familia:family, Revision:revision, Estado:status, CPU:cpu, Memoria:memory}'

# Resultado esperado:
# {
#   "Familia": "shopapi-api",
#   "Revision": 1,
#   "Estado": "ACTIVE",
#   "CPU": "256",
#   "Memoria": "512"
# }
```

#### A2.8 — Ejecutar RunTask

```bash
# IMPORTANTE: necesitas la subnet ID y el security group ID de tu VPC
# Obtener la subnet de la VPC por defecto
export SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=default-for-az,Values=true" \
  --region eu-west-1 \
  --query 'Subnets[0].SubnetId' \
  --output text)

# Obtener el security group por defecto
export SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=default" \
  --region eu-west-1 \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

echo "Subnet ID    : ${SUBNET_ID}"
echo "Security Group: ${SG_ID}"

# Ejecutar el task en Fargate
TASK_ARN=$(aws ecs run-task \
  --cluster shopapi-cluster \
  --task-definition shopapi-api \
  --launch-type FARGATE \
  --count 1 \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_ID}],securityGroups=[${SG_ID}],assignPublicIp=ENABLED}" \
  --region eu-west-1 \
  --query 'tasks[0].taskArn' \
  --output text)

echo "Task ARN: ${TASK_ARN}"

# Resultado esperado:
# Task ARN: arn:aws:ecs:eu-west-1:123456789012:task/shopapi-cluster/abc123def456

# Extraer el Task ID del ARN
TASK_ID=$(echo ${TASK_ARN} | awk -F'/' '{print $NF}')
echo "Task ID: ${TASK_ID}"
```

#### A2.9 — Verificar estado del Task

```bash
# Verificar el estado (puede tardar 1-2 minutos en pasar a RUNNING)
aws ecs describe-tasks \
  --cluster shopapi-cluster \
  --tasks ${TASK_ARN} \
  --region eu-west-1 \
  --query 'tasks[0].{Estado:lastStatus, IP:containers[0].networkInterfaces[0].privateIpv4Address}'

# Resultado esperado tras 1-2 minutos:
# {
#   "Estado": "RUNNING",
#   "IP": "10.0.1.X"
# }

# Obtener la IP pública del task
aws ecs describe-tasks \
  --cluster shopapi-cluster \
  --tasks ${TASK_ARN} \
  --region eu-west-1 \
  --query 'tasks[0].attachments[0].details' \
  | jq '.[] | select(.name=="networkInterfaceId") | .value'

# Con el ENI ID, obtener la IP pública
ENI_ID=$(aws ecs describe-tasks \
  --cluster shopapi-cluster \
  --tasks ${TASK_ARN} \
  --region eu-west-1 \
  --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' \
  --output text)

PUBLIC_IP=$(aws ec2 describe-network-interfaces \
  --network-interface-ids ${ENI_ID} \
  --region eu-west-1 \
  --query 'NetworkInterfaces[0].Association.PublicIp' \
  --output text)

echo "IP Publica: ${PUBLIC_IP}"
echo "URL Health: http://${PUBLIC_IP}:8080/health"

# Probar el endpoint (el SG debe permitir el puerto 8080 desde tu IP)
curl -f http://${PUBLIC_IP}:8080/health

# Resultado esperado:
# {"status": "ok", "version": "0.1.0", "env": "production"}
```

#### A2.10 — Consultar logs en CloudWatch

```bash
# Listar los log streams del contenedor
aws logs describe-log-streams \
  --log-group-name /ecs/shopapi \
  --region eu-west-1 \
  --query 'logStreams[*].logStreamName'

# Resultado esperado:
# [
#   "shopapi-api/shopapi-api/abc123def456"
# ]

# Obtener los logs del stream (últimos 50 eventos)
aws logs get-log-events \
  --log-group-name /ecs/shopapi \
  --log-stream-name "shopapi-api/shopapi-api/${TASK_ID}" \
  --region eu-west-1 \
  --limit 50 \
  --query 'events[*].message' \
  --output text

# Resultado esperado:
# INFO:     Started server process [1]
# INFO:     Waiting for application startup.
# INFO:     Application startup complete.
# INFO:     Uvicorn running on http://0.0.0.0:8080 (Press CTRL+C to quit)
```

---

## Fase B: Terraform

La Fase B automatiza exactamente los mismos recursos usando Terraform.
Los archivos están en el directorio `terraform/`.

### Estructura de archivos Terraform

```
terraform/
├── main.tf       # Recursos principales (ECR, ECS, IAM, CloudWatch)
├── variables.tf  # Definición de variables
└── outputs.tf    # Outputs con los ARNs y URIs creados
```

### Ejecución

```bash
cd terraform/

# Inicializar providers
terraform init

# Planificar los cambios
terraform plan -var="account_id=${AWS_ACCOUNT_ID}"

# Aplicar (creará todos los recursos del lab)
terraform apply -var="account_id=${AWS_ACCOUNT_ID}"

# Ver los outputs importantes
terraform output
```

### Outputs esperados

```
ecr_repository_url  = "123456789012.dkr.ecr.eu-west-1.amazonaws.com/shopapi/api"
cluster_arn         = "arn:aws:ecs:eu-west-1:123456789012:cluster/shopapi-cluster"
task_definition_arn = "arn:aws:ecs:eu-west-1:123456789012:task-definition/shopapi-api:1"
log_group_name      = "/ecs/shopapi"
```

> **Nota**: El `null_resource` de Terraform ejecuta el docker build+push automáticamente.
> Asegúrate de tener Docker corriendo y la variable `APP_DIR` configurada.

---

## Validacion

Una vez completado el lab (por CLI o Terraform), verificar:

```bash
# 1. ECR: imagen disponible
aws ecr list-images --repository-name shopapi/api --region eu-west-1

# 2. ECS Cluster: estado ACTIVE
aws ecs describe-clusters --clusters shopapi-cluster --region eu-west-1 \
  --query 'clusters[0].status' --output text
# Esperado: ACTIVE

# 3. Task Definition: registrada y ACTIVE
aws ecs describe-task-definition --task-definition shopapi-api --region eu-west-1 \
  --query 'taskDefinition.status' --output text
# Esperado: ACTIVE

# 4. Task: en estado RUNNING
aws ecs list-tasks --cluster shopapi-cluster --region eu-west-1
aws ecs describe-tasks --cluster shopapi-cluster --tasks <TASK_ARN> --region eu-west-1 \
  --query 'tasks[0].lastStatus' --output text
# Esperado: RUNNING

# 5. CloudWatch Logs: log group existe y tiene streams
aws logs describe-log-groups --log-group-name-prefix /ecs/shopapi --region eu-west-1

# 6. Endpoint HTTP: responde correctamente
curl -f http://<PUBLIC_IP>:8080/health
# Esperado: {"status": "ok", "version": "0.1.0", "env": "production"}
```

---

## Troubleshooting

### Problema 1: Task pasa a estado STOPPED inmediatamente

**Sintomas**: El task arranca pero en segundos cambia de RUNNING a STOPPED.

**Causas y soluciones**:

```bash
# Consultar el motivo de la parada
aws ecs describe-tasks \
  --cluster shopapi-cluster \
  --tasks ${TASK_ARN} \
  --region eu-west-1 \
  --query 'tasks[0].{StopCode:stopCode, StoppedReason:stoppedReason, ContainerReason:containers[0].reason}'

# Causa mas comun: error en la aplicacion (revisar los logs)
aws logs get-log-events \
  --log-group-name /ecs/shopapi \
  --log-stream-name "shopapi-api/shopapi-api/${TASK_ID}" \
  --region eu-west-1
```

**Soluciones comunes**:
- Error de puerto: verificar que la app escucha en el puerto 8080
- Error de imagen: verificar que la imagen se pusheó correctamente a ECR
- Error de permisos: verificar que el execution role tiene la policy adjunta

### Problema 2: Docker login falla ("no basic auth credentials")

**Sintomas**: `docker push` falla con error de autenticación.

**Solucion**:

```bash
# El token de ECR expira cada 12 horas. Renovar el login:
aws ecr get-login-password \
  --region eu-west-1 \
  | docker login \
    --username AWS \
    --password-stdin \
    ${AWS_ACCOUNT_ID}.dkr.ecr.eu-west-1.amazonaws.com

# Verificar que el login fue exitoso antes del push
docker info | grep -i registry
```

### Problema 3: Task en estado PENDING durante mucho tiempo

**Sintomas**: El task tarda mas de 5 minutos en pasar a RUNNING.

**Causas y soluciones**:

```bash
# 1. Verificar que la imagen existe en ECR con el tag correcto
aws ecr describe-images \
  --repository-name shopapi/api \
  --region eu-west-1

# 2. Verificar que el execution role puede hacer pull de ECR
# (comprobar en IAM que la policy AmazonECSTaskExecutionRolePolicy esta adjunta)
aws iam list-attached-role-policies --role-name shopapi-execution-role

# 3. Verificar eventos del task para ver mensajes de error
aws ecs describe-tasks \
  --cluster shopapi-cluster \
  --tasks ${TASK_ARN} \
  --region eu-west-1 \
  --query 'tasks[0].{Status:lastStatus, DesiredStatus:desiredStatus}'

# 4. Revisar que la subnet tiene acceso a internet (NAT Gateway o IP publica)
# Fargate necesita acceso a ECR e internet para descargar la imagen
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=${SUBNET_ID}" \
  --region eu-west-1
```

---

## Limpieza

Ejecutar en orden para evitar errores de dependencias:

```bash
# 1. Parar tasks en ejecucion
TASK_ARNS=$(aws ecs list-tasks \
  --cluster shopapi-cluster \
  --region eu-west-1 \
  --query 'taskArns[]' \
  --output text)

for TASK_ARN in ${TASK_ARNS}; do
  echo "Parando task: ${TASK_ARN}"
  aws ecs stop-task \
    --cluster shopapi-cluster \
    --task ${TASK_ARN} \
    --reason "Limpieza del lab v1" \
    --region eu-west-1
done

# 2. Deregistrar todas las revisiones de la Task Definition
TASK_DEF_ARNS=$(aws ecs list-task-definitions \
  --family-prefix shopapi-api \
  --region eu-west-1 \
  --query 'taskDefinitionArns[]' \
  --output text)

for TD_ARN in ${TASK_DEF_ARNS}; do
  echo "Deregistrando: ${TD_ARN}"
  aws ecs deregister-task-definition \
    --task-definition ${TD_ARN} \
    --region eu-west-1
done

# 3. Eliminar el cluster ECS
aws ecs delete-cluster \
  --cluster shopapi-cluster \
  --region eu-west-1

# 4. Eliminar las imagenes de ECR y luego el repositorio
aws ecr batch-delete-image \
  --repository-name shopapi/api \
  --region eu-west-1 \
  --image-ids imageTag=0.1.0 imageTag=latest

aws ecr delete-repository \
  --repository-name shopapi/api \
  --region eu-west-1 \
  --force  # --force elimina aunque haya imagenes

# 5. Eliminar el log group de CloudWatch
aws logs delete-log-group \
  --log-group-name /ecs/shopapi \
  --region eu-west-1

# 6. Desadjuntar policy y eliminar el IAM role
aws iam detach-role-policy \
  --role-name shopapi-execution-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

aws iam delete-role \
  --role-name shopapi-execution-role

echo "Limpieza completada. Recursos eliminados:"
echo "  - ECR repo: shopapi/api"
echo "  - ECS cluster: shopapi-cluster"
echo "  - Task Definition: shopapi-api"
echo "  - Log Group: /ecs/shopapi"
echo "  - IAM Role: shopapi-execution-role"
```

> O ejecutar directamente el script: `bash cli/99-cleanup.sh`

---

## Conexion con el Examen AWS Solutions Architect Associate

### Preguntas tipicas que cubre este lab

**1. Diferencias entre EC2 y Fargate launch types**
- EC2: gestionas las instancias del cluster, pagas por las instancias aunque no haya tasks
- Fargate: serverless, pagas solo por CPU/memoria reservada durante la ejecucion del task
- *Este lab usa Fargate — sin instancias EC2 que gestionar*

**2. Componentes de ECS**
- **Cluster**: agrupacion logica de tasks/servicios
- **Task Definition**: plantilla (imagen, CPU, mem, red, logs, variables)
- **Task**: instancia en ejecucion de una Task Definition
- **Service**: mantiene N tasks corriendo y las reemplaza si fallan

**3. networkMode: awsvpc**
- En Fargate es OBLIGATORIO usar `awsvpc`
- Cada task obtiene su propia ENI (Elastic Network Interface) y su propia IP
- Permite aplicar Security Groups a nivel de task (no de host)

**4. Execution Role vs Task Role**
- **Execution Role**: usado por el agente de ECS para descargar la imagen de ECR
  y enviar logs a CloudWatch. Permisos sobre la infraestructura de AWS.
- **Task Role**: usado por el CODIGO de la aplicacion para acceder a servicios AWS
  (S3, DynamoDB, etc.). Permisos de negocio.
- *En este lab solo usamos Execution Role*

**5. ECR y el flujo de imagenes**
- ECR es el registry privado de Docker de AWS
- La imagen debe estar en ECR para que Fargate pueda descargarla (sin necesidad de
  credenciales adicionales si el Execution Role tiene permisos ECR)

**6. CloudWatch Logs con awslogs driver**
- El driver `awslogs` envia los logs de stdout/stderr del contenedor a CloudWatch
- Configuracion: `awslogs-group`, `awslogs-region`, `awslogs-stream-prefix`
- El log stream tendra el formato: `{prefix}/{container-name}/{task-id}`

### Puntos clave para el examen

| Concepto | Respuesta |
|----------|-----------|
| networkMode obligatorio en Fargate | `awsvpc` |
| Quien descarga la imagen de ECR | ECS Agent usando el Execution Role |
| Formato del log stream en awslogs | `{prefix}/{container}/{task-id}` |
| CPU minimo en Fargate | 256 (0.25 vCPU) |
| Memoria minima en Fargate | 512 MB |
| Diferencia Task vs Service | Task es one-shot; Service mantiene N tasks en ejecucion |
