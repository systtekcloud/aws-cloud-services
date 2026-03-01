# Lab v6 — Optimización de Costes en ECS Fargate

## Objetivo

Reducir la factura mensual de AWS de la arquitectura ShopAPI (v4/v5) sin sacrificar
disponibilidad ni rendimiento, aplicando cuatro optimizaciones independientes que se
pueden activar en cualquier orden:

1. **VPC Endpoints** — Eliminar el tráfico de NAT Gateway hacia servicios AWS internos
2. **Capacity Providers optimizados** — Mezclar FARGATE y FARGATE_SPOT para reducir coste de cómputo
3. **Graviton ARM64** — Migrar la imagen a arquitectura ARM para aprovechar el descuento del ~20%
4. **CloudWatch Logs** — Configurar retención y verbosidad para evitar almacenamiento innecesario

---

## El problema: coste oculto del NAT Gateway

Con la arquitectura de v4/v5, todos los tasks de ECS corren en **subnets privadas**.
Cualquier llamada a una API de AWS (ECR, CloudWatch Logs, Secrets Manager) sale de la
VPC a través del **NAT Gateway** y regresa por el mismo camino.

```
Task en subnet privada
        │
        ▼
  [NAT Gateway]  ← $0.045/hora + $0.045/GB procesado
        │
        ▼
  Internet pública
        │
        ▼
  api.ecr.eu-west-1.amazonaws.com  ← ¡API de AWS!
        │
        ▼
  Internet pública
        │
        ▼
  [NAT Gateway] de vuelta
        │
        ▼
  Task recibe la respuesta
```

Esto significa que:
- Cada **pull de imagen ECR** (~300 MB por deploy × 4 tasks) pasa por NAT
- Cada **línea de log** enviada a CloudWatch Logs pasa por NAT
- Cada **llamada a Secrets Manager** en el arranque pasa por NAT
- Los **layers de imágenes** almacenados en S3 pasan por NAT

Con 4 tasks, 10 deploys/día y logs moderados, el gasto de NAT Gateway puede superar
el coste del propio cómputo Fargate.

---

## Prerrequisitos

- Lab v4 o v5 completado:
  - Cluster `shopapi-cluster` activo
  - Services `shopapi-api-service` y `shopapi-workers-service` corriendo
  - VPC con 3 subnets privadas (una por AZ) y NAT Gateway
  - Task Security Group (`shopapi-task-sg`) conocido
- AWS CLI configurado:

```bash
export AWS_REGION=eu-west-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=shopapi-vpc" \
  --query 'Vpcs[0].VpcId' --output text)
export CLUSTER_NAME=shopapi-cluster
```

---

## Fase A1 — Análisis de costes base (antes de optimizar)

### Ver el coste actual de NAT Gateway en Cost Explorer

```bash
# Consultar costes de los últimos 30 días desglosados por servicio
aws ce get-cost-and-usage \
  --time-period Start=$(date -d "30 days ago" +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE \
  --filter '{
    "Dimensions": {
      "Key": "SERVICE",
      "Values": ["Amazon Virtual Private Cloud"]
    }
  }' \
  --region eu-west-1 \
  --output table
```

### Ver bytes procesados por el NAT Gateway

```bash
# Obtener el ID del NAT Gateway
NAT_GW_ID=$(aws ec2 describe-nat-gateways \
  --filter "Name=tag:Name,Values=shopapi-nat-gw-a" \
  --query 'NatGateways[0].NatGatewayId' \
  --output text)

echo "NAT Gateway ID: ${NAT_GW_ID}"

# Bytes procesados en las últimas 24 horas
aws cloudwatch get-metric-statistics \
  --namespace AWS/NATGateway \
  --metric-name BytesOutToDestination \
  --dimensions Name=NatGatewayId,Value="${NAT_GW_ID}" \
  --start-time $(date -u -d "24 hours ago" +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 3600 \
  --statistics Sum \
  --output table

# También los bytes de entrada (tráfico de respuesta)
aws cloudwatch get-metric-statistics \
  --namespace AWS/NATGateway \
  --metric-name BytesInFromDestination \
  --dimensions Name=NatGatewayId,Value="${NAT_GW_ID}" \
  --start-time $(date -u -d "24 hours ago" +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 3600 \
  --statistics Sum \
  --output table
```

### Estimación de coste mensual del NAT Gateway (arquitectura v4/v5)

```
Escenario: 4 tasks, 10 deploys/día, logs moderados

Coste fijo NAT Gateway:
  1 NAT GW × $0.045/hora × 730 horas/mes = $32.85/mes

Coste variable (bytes procesados):
  Pull ECR por deploy:
    4 tasks × 300 MB × 10 deploys × 30 días = 360,000 MB = 360 GB
    360 GB × $0.045/GB = $16.20/mes

  CloudWatch Logs (ida + vuelta):
    4 tasks × ~50 MB/día × 30 días = 6,000 MB = 6 GB
    6 GB × 2 (ida y vuelta) × $0.045/GB = $0.54/mes

  Secrets Manager (arranque de tasks):
    4 tasks × ~5 KB × 10 deploys = prácticamente $0

  TOTAL variable: ~$16.74/mes

TOTAL NAT Gateway: $32.85 + $16.74 = ~$49.59/mes
```

> Nota: En producción con más deploys o tasks más grandes, este coste escala
> linealmente. El coste fijo de $32.85 existe aunque no haya ni un byte de tráfico.

---

## Fase A2 — VPC Endpoints

### ¿Qué son los VPC Endpoints?

Un VPC Endpoint es una conexión privada entre tu VPC y un servicio AWS que **no
requiere NAT Gateway, Internet Gateway ni VPN**. El tráfico permanece dentro de la
red troncal de AWS y nunca sale a Internet pública.

Hay dos tipos:

| Tipo | Funcionamiento | Coste | Servicios |
|------|----------------|-------|-----------|
| **Interface Endpoint** (AWS PrivateLink) | Crea una ENI en tu subnet con IP privada. El tráfico va por esa ENI. | $0.01/hora/AZ + $0.01/GB procesado | ECR, CloudWatch Logs, Secrets Manager, STS, la mayoría de servicios AWS |
| **Gateway Endpoint** | Añade una entrada en la tabla de rutas. Sin ENI, sin IP. | **GRATIS** | Solo S3 y DynamoDB |

**Por qué S3 Gateway es gratis:** AWS diseñó los Gateway Endpoints antes que PrivateLink.
Son una optimización de routing, no una funcionalidad de red completa, por eso tienen
coste cero. Los Interface Endpoints despliegan infraestructura real (ENIs) en tu VPC.

**Por qué necesitamos S3 para ECR:** Las imágenes Docker se almacenan en S3 como capas
(layers). Cuando ECR sirve una imagen, `ecr.dkr` gestiona la autenticación pero los
datos de las capas vienen directamente de S3. Sin el endpoint S3, el pull de ECR
sigue saliendo por NAT aunque tengas los endpoints de ECR configurados.

### Los 5 endpoints necesarios para ShopAPI

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│  VPC shopapi-vpc                                                                │
│                                                                                 │
│  Subnets privadas (eu-west-1a/b/c)                                             │
│  ┌─────────────┐                                                                │
│  │  ECS Tasks  │──── ECR pull ──────────────────► [ecr.api endpoint]  ─► ECR   │
│  │             │──── image layers ──────────────► [ecr.dkr endpoint]  ─► ECR   │
│  │             │──── S3 layers ─────────────────► [s3 endpoint]       ─► S3    │
│  │             │──── CloudWatch Logs ────────────► [logs endpoint]     ─► CWL  │
│  │             │──── Secrets Manager ────────────► [secretsmgr endpt]  ─► SM   │
│  └─────────────┘                                                                │
│                                      Sin NAT Gateway. Sin Internet.             │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Endpoint 1: S3 Gateway (GRATIS)

**Para qué sirve:** Capas (layers) de imágenes Docker almacenadas en S3 por ECR.
Sin este endpoint, los pulls de ECR fallan o siguen pasando por NAT aunque tengas
los endpoints de ECR configurados.

```bash
# Obtener las tablas de rutas de las subnets privadas
PRIVATE_ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables \
  --filters \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=tag:Type,Values=private" \
  --query 'RouteTables[*].RouteTableId' \
  --output text | tr '\t' ' ')

echo "Route Tables privadas: ${PRIVATE_ROUTE_TABLE_IDS}"

# Crear endpoint S3 Gateway (no necesita Security Group ni Subnet)
S3_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
  --vpc-id "${VPC_ID}" \
  --vpc-endpoint-type Gateway \
  --service-name "com.amazonaws.eu-west-1.s3" \
  --route-table-ids ${PRIVATE_ROUTE_TABLE_IDS} \
  --tag-specifications 'ResourceType=vpc-endpoint,Tags=[
    {Key=Name,Value=shopapi-vpce-s3},
    {Key=Project,Value=shopapi},
    {Key=Lab,Value=v6}
  ]' \
  --query 'VpcEndpoint.VpcEndpointId' \
  --output text)

echo "S3 Gateway Endpoint creado: ${S3_ENDPOINT_ID}"
```

Salida esperada:
```
Route Tables privadas: rtb-0abc12345 rtb-0def67890 rtb-0ghi11111
S3 Gateway Endpoint creado: vpce-0a1b2c3d4e5f67890
```

> El Gateway Endpoint añade una ruta tipo `pl-XXXXXXXX → vpce-XXXXXXXX` en las
> tablas de rutas seleccionadas. Esta ruta tiene prioridad sobre la ruta default
> de Internet (0.0.0.0/0 → NAT), por eso el tráfico S3 ya no pasa por NAT.

### Security Group para Interface Endpoints

Los Interface Endpoints necesitan un Security Group que permita tráfico HTTPS (443)
desde los tasks de ECS. Crear **un único SG** que usarán todos los Interface Endpoints:

```bash
# Obtener el SG de los tasks de ECS
TASK_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=shopapi-task-sg" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

echo "Task SG: ${TASK_SG_ID}"

# Crear SG para los VPC Endpoints
VPCE_SG_ID=$(aws ec2 create-security-group \
  --group-name "shopapi-vpce-sg" \
  --description "SG para VPC Interface Endpoints de ShopAPI - permite HTTPS desde tasks" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications 'ResourceType=security-group,Tags=[
    {Key=Name,Value=shopapi-vpce-sg},
    {Key=Project,Value=shopapi},
    {Key=Lab,Value=v6}
  ]' \
  --query 'GroupId' \
  --output text)

echo "VPCE SG creado: ${VPCE_SG_ID}"

# Permitir HTTPS (443) desde el SG de los tasks
aws ec2 authorize-security-group-ingress \
  --group-id "${VPCE_SG_ID}" \
  --protocol tcp \
  --port 443 \
  --source-group "${TASK_SG_ID}" \
  --region eu-west-1

echo "Regla de ingress añadida: HTTPS desde ${TASK_SG_ID}"
```

> Por qué solo el puerto 443: todos los servicios AWS usan HTTPS. Los Interface
> Endpoints terminan la conexión TLS con un certificado AWS válido. El tráfico
> dentro de AWS se puede encriptar opcionalmente pero siempre entra por 443.

### Obtener subnets privadas

```bash
# Las 3 subnets privadas (una por AZ)
PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=tag:Type,Values=private" \
  --query 'Subnets[*].SubnetId' \
  --output text | tr '\t' ',')

echo "Subnets privadas: ${PRIVATE_SUBNET_IDS}"
```

### Endpoint 2: ECR API (Interface)

**Para qué sirve:** Autenticación con ECR. El comando `docker login` y las llamadas
`GetAuthorizationToken` pasan por este endpoint.

```bash
ECR_API_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
  --vpc-id "${VPC_ID}" \
  --vpc-endpoint-type Interface \
  --service-name "com.amazonaws.eu-west-1.ecr.api" \
  --subnet-ids $(echo "${PRIVATE_SUBNET_IDS}" | tr ',' ' ') \
  --security-group-ids "${VPCE_SG_ID}" \
  --private-dns-enabled \
  --tag-specifications 'ResourceType=vpc-endpoint,Tags=[
    {Key=Name,Value=shopapi-vpce-ecr-api},
    {Key=Project,Value=shopapi},
    {Key=Lab,Value=v6}
  ]' \
  --query 'VpcEndpoint.VpcEndpointId' \
  --output text)

echo "ECR API Endpoint creado: ${ECR_API_ENDPOINT_ID}"
```

### Endpoint 3: ECR DKR (Interface)

**Para qué sirve:** Pull de imágenes Docker. El daemon Docker usa este endpoint para
descargar las capas de la imagen a través del protocolo HTTP Range Requests de Docker.

```bash
ECR_DKR_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
  --vpc-id "${VPC_ID}" \
  --vpc-endpoint-type Interface \
  --service-name "com.amazonaws.eu-west-1.ecr.dkr" \
  --subnet-ids $(echo "${PRIVATE_SUBNET_IDS}" | tr ',' ' ') \
  --security-group-ids "${VPCE_SG_ID}" \
  --private-dns-enabled \
  --tag-specifications 'ResourceType=vpc-endpoint,Tags=[
    {Key=Name,Value=shopapi-vpce-ecr-dkr},
    {Key=Project,Value=shopapi},
    {Key=Lab,Value=v6}
  ]' \
  --query 'VpcEndpoint.VpcEndpointId' \
  --output text)

echo "ECR DKR Endpoint creado: ${ECR_DKR_ENDPOINT_ID}"
```

> `PrivateDnsEnabled=true` es clave: hace que el nombre DNS público
> `ACCOUNT.dkr.ecr.eu-west-1.amazonaws.com` resuelva a la IP privada del endpoint
> dentro de la VPC. Los tasks no necesitan cambios de configuración: siguen usando
> el mismo hostname pero el tráfico ahora va al endpoint privado.

### Endpoint 4: CloudWatch Logs (Interface)

**Para qué sirve:** El log driver `awslogs` que usan los contenedores para enviar
logs a CloudWatch Logs. Sin este endpoint, cada línea de log pasa por NAT.

```bash
LOGS_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
  --vpc-id "${VPC_ID}" \
  --vpc-endpoint-type Interface \
  --service-name "com.amazonaws.eu-west-1.logs" \
  --subnet-ids $(echo "${PRIVATE_SUBNET_IDS}" | tr ',' ' ') \
  --security-group-ids "${VPCE_SG_ID}" \
  --private-dns-enabled \
  --tag-specifications 'ResourceType=vpc-endpoint,Tags=[
    {Key=Name,Value=shopapi-vpce-logs},
    {Key=Project,Value=shopapi},
    {Key=Lab,Value=v6}
  ]' \
  --query 'VpcEndpoint.VpcEndpointId' \
  --output text)

echo "CloudWatch Logs Endpoint creado: ${LOGS_ENDPOINT_ID}"
```

### Endpoint 5: Secrets Manager (Interface)

**Para qué sirve:** Que el Execution Role pueda obtener los secrets al arrancar el
contenedor sin salir por NAT.

```bash
SM_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
  --vpc-id "${VPC_ID}" \
  --vpc-endpoint-type Interface \
  --service-name "com.amazonaws.eu-west-1.secretsmanager" \
  --subnet-ids $(echo "${PRIVATE_SUBNET_IDS}" | tr ',' ' ') \
  --security-group-ids "${VPCE_SG_ID}" \
  --private-dns-enabled \
  --tag-specifications 'ResourceType=vpc-endpoint,Tags=[
    {Key=Name,Value=shopapi-vpce-secretsmanager},
    {Key=Project,Value=shopapi},
    {Key=Lab,Value=v6}
  ]' \
  --query 'VpcEndpoint.VpcEndpointId' \
  --output text)

echo "Secrets Manager Endpoint creado: ${SM_ENDPOINT_ID}"
```

### Verificar que los endpoints están disponibles

```bash
# Esperar a que los Interface Endpoints estén en estado "available"
echo "Esperando que los endpoints estén disponibles..."

for ENDPOINT_ID in "${ECR_API_ENDPOINT_ID}" "${ECR_DKR_ENDPOINT_ID}" \
                   "${LOGS_ENDPOINT_ID}" "${SM_ENDPOINT_ID}"; do
  aws ec2 wait vpc-endpoint-services-available 2>/dev/null || true

  STATUS=$(aws ec2 describe-vpc-endpoints \
    --vpc-endpoint-ids "${ENDPOINT_ID}" \
    --query 'VpcEndpoints[0].State' \
    --output text)

  echo "  ${ENDPOINT_ID}: ${STATUS}"
done

# Ver todos los endpoints de la VPC
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'VpcEndpoints[*].{ID:VpcEndpointId,Servicio:ServiceName,Estado:State,Tipo:VpcEndpointType}' \
  --output table
```

Salida esperada:
```
---------------------------------------------------------------
| ID            | Servicio                          | Estado    | Tipo      |
|---------------|-----------------------------------|-----------|-----------|
| vpce-001...   | com.amazonaws.eu-west-1.ecr.api   | available | Interface |
| vpce-002...   | com.amazonaws.eu-west-1.ecr.dkr   | available | Interface |
| vpce-003...   | com.amazonaws.eu-west-1.logs      | available | Interface |
| vpce-004...   | com.amazonaws.eu-west-1.s3        | available | Gateway   |
| vpce-005...   | com.amazonaws.eu-west-1.secretsmanager | available | Interface |
---------------------------------------------------------------
```

### Verificar que el tráfico ECR ya no pasa por NAT

```bash
# Antes de los endpoints: forzar un nuevo pull viendo los bytes de NAT
# (hacer esto ANTES de crear los endpoints para tener la baseline)

BEFORE_BYTES=$(aws cloudwatch get-metric-statistics \
  --namespace AWS/NATGateway \
  --metric-name BytesOutToDestination \
  --dimensions Name=NatGatewayId,Value="${NAT_GW_ID}" \
  --start-time $(date -u -d "5 minutes ago" +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 \
  --statistics Sum \
  --query 'Datapoints[0].Sum' \
  --output text)

echo "Bytes NAT antes: ${BEFORE_BYTES}"

# Forzar un redeploy para provocar un pull de ECR
aws ecs update-service \
  --cluster "${CLUSTER_NAME}" \
  --service shopapi-api-service \
  --force-new-deployment \
  --region eu-west-1

# Esperar 2 minutos y medir de nuevo
sleep 120

AFTER_BYTES=$(aws cloudwatch get-metric-statistics \
  --namespace AWS/NATGateway \
  --metric-name BytesOutToDestination \
  --dimensions Name=NatGatewayId,Value="${NAT_GW_ID}" \
  --start-time $(date -u -d "5 minutes ago" +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 \
  --statistics Sum \
  --query 'Datapoints[0].Sum' \
  --output text)

echo "Bytes NAT después: ${AFTER_BYTES}"
echo "Diferencia: el pull de ECR ya no pasa por NAT"
```

---

## Fase A3 — Capacity Provider Strategy optimizada

### Revisar la estrategia actual

```bash
# Ver la estrategia actual del servicio API
aws ecs describe-services \
  --cluster "${CLUSTER_NAME}" \
  --services shopapi-api-service \
  --query 'services[0].capacityProviderStrategy' \
  --output table

# Ver la estrategia del servicio Workers
aws ecs describe-services \
  --cluster "${CLUSTER_NAME}" \
  --services shopapi-workers-service \
  --query 'services[0].capacityProviderStrategy' \
  --output table
```

### Concepto: FARGATE vs FARGATE_SPOT

| Característica | FARGATE | FARGATE_SPOT |
|----------------|---------|--------------|
| Precio | Tarifa completa | ~70% de descuento |
| Disponibilidad | Garantizada | AWS puede interrumpir con 2 min de aviso |
| SIGTERM ante interrupción | No aplica | Sí — debes manejar la señal |
| Uso recomendado | Tasks críticos, APIs | Workers, tareas batch, procesamiento asíncrono |
| Parámetros de la estrategia | `base`, `weight` | Solo `weight` (no se garantiza base) |

**Parámetros de `capacityProviderStrategy`:**

- `base`: número mínimo de tasks que siempre van a este provider (solo tiene sentido en FARGATE)
- `weight`: proporción relativa. Si FARGATE tiene weight=1 y FARGATE_SPOT tiene weight=3,
  el 75% de los tasks adicionales van a SPOT

### Estrategia recomendada para la API (tolerante a interrupciones parciales)

```bash
# Estrategia: 2 tasks garantizados en FARGATE + tasks adicionales en FARGATE_SPOT
# Con desired=4: 2 en FARGATE (base) + 2 en FARGATE_SPOT (weight)
aws ecs update-service \
  --cluster "${CLUSTER_NAME}" \
  --service shopapi-api-service \
  --capacity-provider-strategy \
    capacityProvider=FARGATE,weight=1,base=2 \
    capacityProvider=FARGATE_SPOT,weight=3 \
  --region eu-west-1
```

### Estrategia optimizada para Workers (máximo SPOT)

```bash
# Workers son tolerantes a interrupciones: la cola SQS reencola mensajes
# Estrategia: 1 task garantizado en FARGATE + el resto en FARGATE_SPOT
aws ecs update-service \
  --cluster "${CLUSTER_NAME}" \
  --service shopapi-workers-service \
  --capacity-provider-strategy \
    capacityProvider=FARGATE,weight=1,base=1 \
    capacityProvider=FARGATE_SPOT,weight=9 \
  --region eu-west-1
```

### Manejar la interrupción de FARGATE_SPOT (SIGTERM handler)

Cuando AWS interrumpe un task FARGATE_SPOT, envía `SIGTERM` con **2 minutos de aviso**
antes de forzar `SIGKILL`. La aplicación debe:

1. Capturar `SIGTERM`
2. Dejar de aceptar nuevas solicitudes
3. Terminar las solicitudes en curso
4. Liberar recursos y salir limpiamente

Ejemplo en FastAPI (agregar al `main.py` de ShopAPI):

```python
import signal
import asyncio
import logging
from contextlib import asynccontextmanager

logger = logging.getLogger(__name__)
_shutdown_event = asyncio.Event()

def _handle_sigterm(signum, frame):
    """
    Handler para SIGTERM (interrupción de FARGATE_SPOT).
    Da 2 minutos para terminar las solicitudes en curso.
    """
    logger.warning("SIGTERM recibido — iniciando shutdown graceful (FARGATE_SPOT interrupted)")
    _shutdown_event.set()

signal.signal(signal.SIGTERM, _handle_sigterm)

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    logger.info("ShopAPI iniciando...")
    yield
    # Shutdown (se ejecuta al recibir SIGTERM)
    logger.warning("ShopAPI en shutdown — esperando solicitudes en curso...")
    await asyncio.sleep(5)  # Tiempo para terminar solicitudes activas
    logger.info("ShopAPI terminado correctamente")

app = FastAPI(lifespan=lifespan)
```

Para Workers con SQS, el handler debe **devolver los mensajes a la cola**:

```python
def _handle_sigterm_worker(signum, frame):
    logger.warning("SIGTERM recibido en Worker — deteniendo polling de SQS")
    # El mensaje actual tiene visibility timeout: si no se hace delete,
    # SQS lo reencola automáticamente cuando expire el timeout.
    # No hay que hacer nada extra si el mensaje no se ha procesado aún.
    # Si está a mitad de proceso: cambiar visibility timeout a 0 para reencolar ahora.
    global _stop_polling
    _stop_polling = True
```

### Verificar la distribución de tasks por capacity provider

```bash
# Ver en qué capacity provider está corriendo cada task
aws ecs list-tasks \
  --cluster "${CLUSTER_NAME}" \
  --service-name shopapi-api-service \
  --output text | awk '{print $2}' | while read TASK_ARN; do
    aws ecs describe-tasks \
      --cluster "${CLUSTER_NAME}" \
      --tasks "${TASK_ARN}" \
      --query 'tasks[0].{ID:taskArn,Provider:capacityProviderName,Status:lastStatus}' \
      --output json
  done | jq -s '.'
```

---

## Fase A4 — Graviton ARM64

### ¿Qué es Graviton?

AWS Graviton es el procesador ARM de AWS. En Fargate, usar ARM64 cuesta
aproximadamente un **20% menos** que x86_64 con el mismo rendimiento o mejor
para workloads Python/FastAPI.

```
Fargate x86_64:  vCPU = $0.04856/hora,  GB RAM = $0.00532/hora
Fargate ARM64:   vCPU = $0.03868/hora,  GB RAM = $0.00425/hora
                 ↑ 20.3% más barato      ↑ 20.1% más barato
```

### Verificar compatibilidad de dependencias Python

La mayoría de librerías Python son puro Python y corren en ARM sin cambios.
Las que usan extensiones C compiladas necesitan wheels ARM64:

```bash
# Las dependencias clave de ShopAPI son compatibles con ARM64:
# - fastapi: puro Python (sí)
# - uvicorn: puro Python (sí)
# - boto3 / botocore: puro Python con algunas extensiones C (sí, hay wheels ARM)
# - pydantic: usa Cython compilado, hay wheels ARM64 desde pydantic 1.9
# - cryptography: extensiones C, hay wheels ARM64 en PyPI

# Verificar que los wheels existen para linux/arm64:
pip download \
  --platform manylinux2014_aarch64 \
  --only-binary=:all: \
  --no-deps \
  fastapi uvicorn boto3 pydantic cryptography \
  -d /tmp/arm64-wheels/

ls -la /tmp/arm64-wheels/
```

### Build multi-arquitectura con docker buildx

```bash
# Crear un builder con soporte multi-plataforma (una vez por máquina)
docker buildx create --name shopapi-builder --use --bootstrap

# Build SOLO para ARM64 (si el destino es Graviton)
docker buildx build \
  --platform linux/arm64 \
  --tag "${ACCOUNT_ID}.dkr.ecr.eu-west-1.amazonaws.com/shopapi/api:arm64-latest" \
  --push \
  /path/to/shopapi/

# Build multi-arch (x86_64 + ARM64 en la misma imagen)
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag "${ACCOUNT_ID}.dkr.ecr.eu-west-1.amazonaws.com/shopapi/api:latest" \
  --push \
  /path/to/shopapi/
```

> Nota: `--push` es necesario con buildx multi-arch porque los manifests
> multi-plataforma no se pueden almacenar en el daemon local de Docker.

### Registrar la Task Definition con ARM64

Añadir el bloque `runtimePlatform` a la Task Definition:

```bash
# Obtener la Task Definition actual como JSON
aws ecs describe-task-definition \
  --task-definition shopapi-api \
  --query 'taskDefinition' \
  --output json > /tmp/shopapi-api-current.json

# Crear la nueva versión con runtimePlatform ARM64
cat /tmp/shopapi-api-current.json | python3 -c "
import json, sys

td = json.load(sys.stdin)

# Campos que no se pueden incluir al re-registrar
for key in ['taskDefinitionArn', 'revision', 'status', 'requiresAttributes',
            'placementConstraints', 'compatibilities', 'registeredAt', 'registeredBy']:
    td.pop(key, None)

# Añadir runtimePlatform ARM64
td['runtimePlatform'] = {
    'cpuArchitecture': 'ARM64',
    'operatingSystemFamily': 'LINUX'
}

print(json.dumps(td, indent=2))
" > /tmp/shopapi-api-arm64.json

# Registrar la nueva Task Definition
NEW_ARM64_TASK_DEF=$(aws ecs register-task-definition \
  --cli-input-json file:///tmp/shopapi-api-arm64.json \
  --region eu-west-1 \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

echo "Nueva Task Definition ARM64: ${NEW_ARM64_TASK_DEF}"

# Actualizar el servicio para usar ARM64
aws ecs update-service \
  --cluster "${CLUSTER_NAME}" \
  --service shopapi-api-service \
  --task-definition "${NEW_ARM64_TASK_DEF}" \
  --region eu-west-1
```

### Comparativa de precios (eu-west-1, febrero 2026)

```
Configuración típica: 0.25 vCPU, 0.5 GB RAM, 4 tasks, 730 h/mes

x86_64:
  4 tasks × (0.25 vCPU × $0.04856/h + 0.5 GB × $0.00532/h) × 730 h
  = 4 × (0.01214 + 0.00266) × 730
  = 4 × 0.01480 × 730
  = $43.22/mes

ARM64:
  4 tasks × (0.25 vCPU × $0.03868/h + 0.5 GB × $0.00425/h) × 730 h
  = 4 × (0.00967 + 0.002125) × 730
  = 4 × 0.011795 × 730
  = $34.44/mes

Ahorro mensual: $43.22 - $34.44 = $8.78/mes (~20.3%)
```

### Caveat: FARGATE_SPOT + ARM64

FARGATE_SPOT también tiene precios reducidos para ARM64:

```
FARGATE_SPOT ARM64: vCPU ≈ $0.01236/h, GB ≈ $0.00136/h
(varía según la disponibilidad de capacidad spot en cada AZ y momento)
```

Combinar ARM64 + FARGATE_SPOT puede dar hasta un **65-70% de descuento** respecto
a FARGATE x86_64 para workloads tolerantes a interrupciones.

---

## Fase A5 — Optimizar CloudWatch Logs

### Revisar la retención actual

```bash
# Ver los log groups de ShopAPI y su retención
aws logs describe-log-groups \
  --log-group-name-prefix "/ecs/shopapi" \
  --query 'logGroups[*].{Nombre:logGroupName,RetenciónDías:retentionInDays,TamañoGB:storedBytes}' \
  --output table
```

Si `RetenciónDías` aparece como `None`, los logs se guardan **indefinidamente** y
se cobra por cada GB almacenado ($0.03/GB/mes en eu-west-1).

### Configurar retención de 30 días (dev) y 90 días (prod)

```bash
# Servicios de logs existentes
LOG_GROUPS=(
  "/ecs/shopapi-api"
  "/ecs/shopapi-workers"
)

# Para entornos de desarrollo: 30 días
for LOG_GROUP in "${LOG_GROUPS[@]}"; do
  aws logs put-retention-policy \
    --log-group-name "${LOG_GROUP}" \
    --retention-in-days 30 \
    --region eu-west-1

  echo "Retención 30 días configurada en: ${LOG_GROUP}"
done

# Para producción: usar 90 días (balance entre coste y capacidad de análisis)
# aws logs put-retention-policy \
#   --log-group-name "/ecs/shopapi-api" \
#   --retention-in-days 90
```

### Reducir verbosidad del logger en producción

En el código de ShopAPI (`app/main.py` o `app/core/logging.py`), cambiar el nivel
de log según el entorno:

```python
import logging
import os

ENV = os.getenv("ENV", "development")

# En producción, INFO es excesivo: cada request genera una línea de log
# En producción, usar WARNING para reducir volumen ~80%
LOG_LEVEL = logging.WARNING if ENV == "production" else logging.INFO

logging.basicConfig(
    level=LOG_LEVEL,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)

# Silenciar librerías verbosas en producción
if ENV == "production":
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)
    logging.getLogger("botocore").setLevel(logging.ERROR)
    logging.getLogger("boto3").setLevel(logging.ERROR)
```

### Estimar el ahorro de reducir logs

```
Escenario: 4 tasks, 100 req/s en producción

Con INFO (una línea por request):
  4 tasks × 100 req/s × 200 bytes/línea × 86400 s/día × 30 días = ~2.07 TB/mes
  Ingesta CloudWatch: 2.07 TB × $0.57/GB = $1,179.90/mes  ← ¡Problema grave!
  Almacenamiento (30 días): 2.07 TB × $0.03/GB = $62.10/mes

Con WARNING (solo errores):
  Asumiendo 0.1% de errores: 100 req/s × 0.1% = 0.1 líneas/s por task
  4 tasks × 0.1 líneas/s × 200 bytes × 86400 s × 30 días = ~2 GB/mes
  Ingesta CloudWatch: 2 GB × $0.57/GB = $1.14/mes
  Almacenamiento (30 días): 2 GB × $0.03/GB = $0.06/mes

Ahorro en logs: ~$1,241/mes en un sistema con 100 req/s
```

> Nota: Para producción real, considera usar un sampler de logs (solo loguear
> el 1% de los requests 2xx) o exportar logs a S3 con lifecycle a Glacier.

---

## Análisis de costes final (después de optimizar)

### Tabla comparativa antes/después

| Componente | Antes (v5) $/mes | Después (v6) $/mes | Ahorro |
|------------|-------------------|---------------------|--------|
| NAT Gateway fijo (1 GW) | $32.85 | $32.85 * | $0 |
| NAT Gateway tráfico ECR | $16.20 | $0 | $16.20 |
| NAT Gateway tráfico Logs | $0.54 | $0 | $0.54 |
| VPC Interface Endpoints (4×3AZ) | $0 | $21.90 | -$21.90 |
| Fargate compute (x86_64) | $43.22 | $0 | — |
| Fargate compute (ARM64) | — | $34.44 | $8.78 |
| FARGATE_SPOT savings (~60%) | $0 | -$20.66 | $20.66 |
| CloudWatch Logs ingesta | $65.55 | $1.14 | $64.41 |
| CloudWatch Logs storage | $6.21 | $0.06 | $6.15 |
| **TOTAL** | **$164.57** | **$69.73** | **$94.84** |

*El NAT Gateway sigue siendo necesario para otros recursos (acceso a Internet general).
Si ShopAPI fuera el único workload, el NAT podría eliminarse completamente.

**Ahorro mensual estimado: ~$94.84 (~57.6%)**

### Punto de equilibrio (break-even): NAT vs VPC Endpoints

Los Interface Endpoints cuestan $0.01/hora por AZ. Con 3 AZs y 4 endpoints Interface:

```
Coste fijo VPC Endpoints:
  4 endpoints × 3 AZs × $0.01/hora × 730 horas = $87.60/mes

Coste fijo NAT Gateway:
  1 NAT GW × $0.045/hora × 730 horas = $32.85/mes

Break-even en tráfico:
  Coste variable NAT = Coste fijo extra de Endpoints
  GB × $0.045 = ($87.60 - $32.85) = $54.75
  GB = $54.75 / $0.045 = 1,217 GB/mes

Conclusión: Si tu workload procesa MÁS de ~1,200 GB/mes de tráfico hacia
servicios AWS (ECR, Logs, Secrets), los VPC Endpoints salen a cuenta.
Para ShopAPI con 4 tasks y deploys frecuentes, estamos en ~370 GB/mes →
los endpoints NO salen a cuenta solo por el tráfico.

Sin embargo, los endpoints también mejoran:
- Latencia (tráfico no sale de la red AWS)
- Seguridad (no hay paso por Internet)
- SLAs (sin dependencia del NAT Gateway)

Para un portfolio técnico/examen SAA, la justificación es arquitectural además de económica.
```

---

## Troubleshooting

### Escenario 1: Tasks en estado PROVISIONING tras crear los VPC Endpoints

**Síntoma:** Después de crear los endpoints, los tasks se quedan en `PROVISIONING`
y nunca pasan a `RUNNING`.

**Causa A: Falta el endpoint S3 Gateway**

ECR usa S3 para almacenar los layers. Sin el Gateway Endpoint de S3, el pull de
ECR falla silenciosamente o muy despacio:

```bash
# Verificar que el endpoint S3 existe y está en estado available
aws ec2 describe-vpc-endpoints \
  --filters \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=service-name,Values=com.amazonaws.eu-west-1.s3" \
  --query 'VpcEndpoints[*].{Estado:State,Tipo:VpcEndpointType,RouteTables:RouteTableIds}' \
  --output table

# Verificar que las route tables de las subnets privadas tienen la ruta pl-*
aws ec2 describe-route-tables \
  --filters "Name=tag:Type,Values=private" \
  --query 'RouteTables[*].Routes[?DestinationPrefixListId!=`null`]' \
  --output table
```

**Causa B: Security Group del endpoint no permite tráfico desde los tasks**

```bash
# Ver las reglas del SG del endpoint
aws ec2 describe-security-groups \
  --group-ids "${VPCE_SG_ID}" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output table

# Si falta la regla, añadirla:
aws ec2 authorize-security-group-ingress \
  --group-id "${VPCE_SG_ID}" \
  --protocol tcp \
  --port 443 \
  --source-group "${TASK_SG_ID}"
```

**Diagnóstico rápido:**

```bash
# Ver los stopped tasks para ver el motivo de fallo
aws ecs list-tasks \
  --cluster "${CLUSTER_NAME}" \
  --desired-status STOPPED \
  --output text | head -5 | awk '{print $2}' | while read TASK_ARN; do
    aws ecs describe-tasks \
      --cluster "${CLUSTER_NAME}" \
      --tasks "${TASK_ARN}" \
      --query 'tasks[0].{Stop:stoppedReason,Container:containers[0].reason}' \
      --output json
  done
```

---

### Escenario 2: Pull ECR falla después de crear el endpoint

**Síntoma:** Tasks fallan con `CannotPullContainerError: Error response from daemon:
Head ... 403 Forbidden` o `no basic auth credentials`.

**Causa: VPC Endpoint Policy demasiado restrictiva**

Por defecto, los VPC Endpoints tienen una policy permisiva (`"Principal": "*"`).
Si se personalizó la policy, puede estar bloqueando las llamadas de ECR:

```bash
# Ver la policy actual del endpoint ECR API
aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids "${ECR_API_ENDPOINT_ID}" \
  --query 'VpcEndpoints[0].PolicyDocument' \
  --output text | python3 -m json.tool

# Restablecer la policy a la permisiva por defecto (Full Access)
aws ec2 modify-vpc-endpoint \
  --vpc-endpoint-id "${ECR_API_ENDPOINT_ID}" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Principal": "*",
        "Effect": "Allow",
        "Action": "*",
        "Resource": "*"
      }
    ]
  }'
```

Si quieres una policy restrictiva para ECR, esta es la mínima funcional:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowECRAuth",
      "Principal": "*",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowECRPull",
      "Principal": "*",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability"
      ],
      "Resource": "arn:aws:ecr:eu-west-1:ACCOUNT_ID:repository/shopapi/*"
    }
  ]
}
```

---

### Escenario 3: FARGATE_SPOT interrumpe workers y hay mensajes perdidos en SQS

**Síntoma:** Tras una interrupción de FARGATE_SPOT, algunos mensajes de SQS no se
procesaron ni se reencolan: desaparecen de la cola.

**Causa A: Visibility Timeout demasiado corto**

Si el visibility timeout de la cola SQS es menor que el tiempo de procesamiento
del Worker, el mensaje vuelve a ser visible antes de que el Worker termine. Si el
Worker es interrumpido justo cuando está procesando, el mensaje puede procesarse
dos veces o perderse si el timeout ya expiró.

```bash
# Verificar el visibility timeout actual
aws sqs get-queue-attributes \
  --queue-url "https://sqs.eu-west-1.amazonaws.com/${ACCOUNT_ID}/shopapi-jobs" \
  --attribute-names VisibilityTimeout \
  --output table

# Ajustar visibility timeout a 5 minutos (tiempo de procesamiento × 2 + 2 min de SIGTERM)
aws sqs set-queue-attributes \
  --queue-url "https://sqs.eu-west-1.amazonaws.com/${ACCOUNT_ID}/shopapi-jobs" \
  --attributes VisibilityTimeout=300
```

**Causa B: El Worker hace `DeleteMessage` antes de terminar el procesamiento**

El patrón correcto es:
1. Recibir el mensaje (el mensaje queda invisible durante el VisibilityTimeout)
2. Procesar el mensaje completamente
3. Solo entonces, hacer `DeleteMessage`

Si el Worker es interrumpido entre el paso 2 y 3, el mensaje vuelve a la cola
automáticamente cuando expira el VisibilityTimeout. No se pierde.

```python
# Patrón correcto en el Worker:
def process_message(message):
    try:
        # 1. Procesar (puede tardar minutos)
        result = do_heavy_processing(message['Body'])

        # 2. Solo eliminar si el procesamiento fue exitoso
        sqs.delete_message(
            QueueUrl=QUEUE_URL,
            ReceiptHandle=message['ReceiptHandle']
        )
        return result

    except Exception as e:
        # No hacer delete: el mensaje volverá a la cola al expirar el visibility timeout
        logger.error(f"Error procesando mensaje: {e}")
        raise
```

**Causa C: Falta Dead Letter Queue (DLQ)**

Si un mensaje falla repetidamente (porque el Worker no puede procesarlo), va a
quedarse en la cola y bloquear a otros Workers. Configurar una DLQ:

```bash
# Crear DLQ
DLQ_URL=$(aws sqs create-queue \
  --queue-name "shopapi-jobs-dlq" \
  --attributes '{"MessageRetentionPeriod":"1209600"}' \
  --query 'QueueUrl' \
  --output text)

DLQ_ARN=$(aws sqs get-queue-attributes \
  --queue-url "${DLQ_URL}" \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' \
  --output text)

# Configurar la cola principal para enviar a DLQ tras 3 intentos fallidos
aws sqs set-queue-attributes \
  --queue-url "https://sqs.eu-west-1.amazonaws.com/${ACCOUNT_ID}/shopapi-jobs" \
  --attributes "{
    \"RedrivePolicy\": \"{\\\"deadLetterTargetArn\\\":\\\"${DLQ_ARN}\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"
  }"
```

---

## Limpieza

> Los VPC Endpoints de tipo Interface tienen coste por hora ($0.01/hora/AZ).
> Al terminar el lab, eliminarlos para evitar cargos continuos.

```bash
# Ver todos los endpoints del lab v6
aws ec2 describe-vpc-endpoints \
  --filters \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=tag:Lab,Values=v6" \
  --query 'VpcEndpoints[*].VpcEndpointId' \
  --output text

# Ejecutar el script de limpieza:
bash /home/sergi/DevOpsProjects/aws/services/ecs/labs/v6-cost-optimization/cli/99-cleanup.sh
```

Ver también `cli/99-cleanup.sh` para la limpieza completa de todos los recursos del lab.

---

## Conceptos clave para el examen SAA

| Concepto | Detalle |
|----------|---------|
| Gateway Endpoint | Solo para S3 y DynamoDB. Gratis. Añade ruta en tabla de rutas. No necesita SG. |
| Interface Endpoint (PrivateLink) | Para todos los demás servicios AWS. $0.01/hora/AZ. Crea ENI en subnet. Necesita SG con puerto 443. |
| `PrivateDnsEnabled=true` | Hace que el hostname público del servicio resuelva a IP privada dentro de la VPC. Sin esto, hay que usar el nombre DNS del endpoint (menos conveniente). |
| FARGATE_SPOT `base` | El parámetro `base` en FARGATE_SPOT no garantiza nada — AWS puede interrumpir esos tasks. Usar `base` solo en el provider FARGATE. |
| Break-even NAT vs Endpoints | Con menos de ~1,200 GB/mes de tráfico a servicios AWS, el NAT Gateway es más barato que los Interface Endpoints. La decisión también tiene componente de seguridad y latencia. |
| `runtimePlatform` | Campo de la Task Definition que especifica la arquitectura CPU. `ARM64` activa Graviton con ~20% de descuento. |
| SIGTERM en FARGATE_SPOT | AWS envía SIGTERM 2 minutos antes de terminar un task SPOT. La app debe manejar esta señal para terminar limpiamente. Si no, los requests en curso se pierden. |
| CloudWatch Logs pricing | Ingesta: $0.57/GB. Almacenamiento: $0.03/GB/mes. La ingesta es el componente dominante — reducir verbosidad tiene gran impacto. |
| Visibility Timeout SQS | Tiempo que un mensaje permanece invisible tras ser recibido. Debe ser mayor que el tiempo máximo de procesamiento para evitar duplicados en caso de reintentos. |
