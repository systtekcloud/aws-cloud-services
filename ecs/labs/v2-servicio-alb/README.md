# Lab v2: ECS Service con ALB — ShopAPI

## Objetivo

Transformar el `RunTask` manual del Lab v1 en un **ECS Service** de alta disponibilidad con:

- VPC personalizada con subnets públicas y privadas en 2 zonas de disponibilidad
- Application Load Balancer (ALB) en subnets públicas
- ECS Service ejecutando en subnets privadas con modo de red `awsvpc`
- Security Groups encadenados: ALB SG → Task SG
- Rolling update sin downtime con circuit breaker

---

## Arquitectura

```
                           Internet
                              │
                    ┌─────────┴─────────┐
                    │                   │
              AZ: eu-west-1a      AZ: eu-west-1b
              10.0.1.0/24         10.0.2.0/24
          [Public Subnet A]    [Public Subnet B]
                    │                   │
              ┌─────┴───────────────────┘
              │
        [ALB: shopapi-alb]
        Security Group: shopapi-alb-sg
        Inbound: 0.0.0.0/0 → puerto 80
              │
        [Target Group: shopapi-tg]
        Tipo: IP  |  Puerto: 8080
        Health check: GET /health
              │
    ┌─────────┴─────────┐
    │                   │
AZ: eu-west-1a    AZ: eu-west-1b
10.0.11.0/24      10.0.12.0/24
[Private Subnet A] [Private Subnet B]
    │                   │
[ECS Task]          [ECS Task]
shopapi-api         shopapi-api
Puerto: 8080        Puerto: 8080
SG: shopapi-task-sg (inbound solo desde shopapi-alb-sg)

[NAT Gateway]  ←  en Public Subnet A, para que las tasks
                   privadas puedan descargar imágenes ECR
```

### Resumen de CIDRs

| Recurso            | CIDR / AZ         |
|--------------------|-------------------|
| VPC                | 10.0.0.0/16       |
| Public Subnet A    | 10.0.1.0/24 (AZ-a)|
| Public Subnet B    | 10.0.2.0/24 (AZ-b)|
| Private Subnet A   | 10.0.11.0/24 (AZ-a)|
| Private Subnet B   | 10.0.12.0/24 (AZ-b)|

---

## Prerrequisitos

- Haber completado el **Lab v1** (imagen en ECR, cluster ECS creado)
- Imagen `shopapi/api:latest` disponible en ECR (`eu-west-1`)
- AWS CLI configurado con perfil o credenciales válidas
- Permisos: `AmazonECS_FullAccess`, `ElasticLoadBalancingFullAccess`, `AmazonVPCFullAccess`
- Terraform >= 1.5 (solo para Fase B)

Verificar prerrequisitos:

```bash
# Verificar imagen en ECR
aws ecr describe-images \
  --repository-name shopapi/api \
  --region eu-west-1 \
  --query 'imageDetails[*].imageTags'

# Verificar cluster ECS
aws ecs describe-clusters \
  --clusters shopapi-cluster \
  --region eu-west-1 \
  --query 'clusters[0].{status:status,activeServices:activeServicesCount}'
```

---

## Fase A: Despliegue Manual

### A1: Consola AWS (pasos de alto nivel)

#### Paso 1 — Crear la VPC

1. VPC > "Create VPC" > seleccionar **"VPC and more"** (wizard)
2. Nombre: `shopapi-vpc`, CIDR: `10.0.0.0/16`
3. 2 AZs, 2 subnets públicas, 2 privadas
4. Habilitar 1 NAT Gateway (en AZ-a)
5. Sin endpoints S3 (los añadiremos en labs posteriores)

#### Paso 2 — Crear Security Groups

1. EC2 > Security Groups > Create:
   - **shopapi-alb-sg**: inbound TCP 80 desde `0.0.0.0/0`
   - **shopapi-task-sg**: inbound TCP 8080 desde `shopapi-alb-sg` (ID del SG)

#### Paso 3 — Crear el ALB

1. EC2 > Load Balancers > Create > Application Load Balancer
2. Nombre: `shopapi-alb`, internet-facing, IPv4
3. VPC: `shopapi-vpc`, subnets públicas AZ-a y AZ-b
4. Security Group: `shopapi-alb-sg`
5. Target Group: nuevo, tipo IP, puerto 8080, VPC shopapi-vpc
6. Health check: protocolo HTTP, path `/health`
7. Listener: HTTP:80 → forward al target group

#### Paso 4 — Crear el ECS Service

1. ECS > Clusters > shopapi-cluster > Create Service
2. Compute: Fargate, desiredCount: 2
3. Task Definition: shopapi-api (última revisión)
4. VPC: shopapi-vpc, subnets privadas, SG: shopapi-task-sg
5. Load balancer: seleccionar ALB `shopapi-alb`, container shopapi-api:8080
6. Health check grace period: 60 segundos

---

### A2: AWS CLI — Comandos Completos

> Los scripts en `cli/` automatizan todos estos pasos. Se documentan aquí para entender cada operación.

#### Paso 1: VPC y Networking

```bash
# 1.1 Crear la VPC
aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=shopapi-vpc}]' \
  --region eu-west-1

# Output esperado:
# {
#   "Vpc": {
#     "VpcId": "vpc-0abc123def456789",
#     "CidrBlock": "10.0.0.0/16",
#     "State": "available"
#   }
# }

VPC_ID="vpc-0abc123def456789"

# 1.2 Crear subnets públicas
aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.1.0/24 \
  --availability-zone eu-west-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=shopapi-public-a}]' \
  --region eu-west-1

aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.2.0/24 \
  --availability-zone eu-west-1b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=shopapi-public-b}]' \
  --region eu-west-1

# 1.3 Crear subnets privadas
aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.11.0/24 \
  --availability-zone eu-west-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=shopapi-private-a}]' \
  --region eu-west-1

aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.12.0/24 \
  --availability-zone eu-west-1b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=shopapi-private-b}]' \
  --region eu-west-1

# 1.4 Internet Gateway
aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=shopapi-igw}]' \
  --region eu-west-1

IGW_ID="igw-0abc123"

aws ec2 attach-internet-gateway \
  --internet-gateway-id $IGW_ID \
  --vpc-id $VPC_ID \
  --region eu-west-1

# 1.5 NAT Gateway (necesita Elastic IP primero)
aws ec2 allocate-address \
  --domain vpc \
  --region eu-west-1

# Output esperado:
# { "AllocationId": "eipalloc-0abc123", "PublicIp": "54.x.x.x" }

EIP_ALLOC_ID="eipalloc-0abc123"
PUBLIC_SUBNET_A="subnet-0abc111"

aws ec2 create-nat-gateway \
  --subnet-id $PUBLIC_SUBNET_A \
  --allocation-id $EIP_ALLOC_ID \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=shopapi-nat}]' \
  --region eu-west-1

# Esperar a que esté disponible (~60 segundos)
aws ec2 wait nat-gateway-available \
  --filter "Name=tag:Name,Values=shopapi-nat" \
  --region eu-west-1

NAT_GW_ID="nat-0abc123"

# 1.6 Route table pública (con ruta a IGW)
aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=shopapi-rt-public}]' \
  --region eu-west-1

RT_PUBLIC_ID="rtb-0abc111"

aws ec2 create-route \
  --route-table-id $RT_PUBLIC_ID \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $IGW_ID \
  --region eu-west-1

# Asociar a subnets públicas
aws ec2 associate-route-table \
  --route-table-id $RT_PUBLIC_ID \
  --subnet-id $PUBLIC_SUBNET_A \
  --region eu-west-1

aws ec2 associate-route-table \
  --route-table-id $RT_PUBLIC_ID \
  --subnet-id $PUBLIC_SUBNET_B \
  --region eu-west-1

# 1.7 Route table privada (con ruta a NAT GW)
aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=shopapi-rt-private}]' \
  --region eu-west-1

RT_PRIVATE_ID="rtb-0abc222"

aws ec2 create-route \
  --route-table-id $RT_PRIVATE_ID \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id $NAT_GW_ID \
  --region eu-west-1

aws ec2 associate-route-table \
  --route-table-id $RT_PRIVATE_ID \
  --subnet-id $PRIVATE_SUBNET_A \
  --region eu-west-1

aws ec2 associate-route-table \
  --route-table-id $RT_PRIVATE_ID \
  --subnet-id $PRIVATE_SUBNET_B \
  --region eu-west-1
```

#### Paso 2: Security Groups y ALB

```bash
# 2.1 SG para el ALB
aws ec2 create-security-group \
  --group-name shopapi-alb-sg \
  --description "SG para el ALB de ShopAPI" \
  --vpc-id $VPC_ID \
  --region eu-west-1

ALB_SG_ID="sg-0abc111"

aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG_ID \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0 \
  --region eu-west-1

# 2.2 SG para las ECS Tasks (inbound solo desde el ALB SG)
aws ec2 create-security-group \
  --group-name shopapi-task-sg \
  --description "SG para las Tasks de ShopAPI - solo trafico desde ALB" \
  --vpc-id $VPC_ID \
  --region eu-west-1

TASK_SG_ID="sg-0abc222"

aws ec2 authorize-security-group-ingress \
  --group-id $TASK_SG_ID \
  --protocol tcp \
  --port 8080 \
  --source-group $ALB_SG_ID \
  --region eu-west-1

# 2.3 Crear ALB
aws elbv2 create-load-balancer \
  --name shopapi-alb \
  --subnets $PUBLIC_SUBNET_A $PUBLIC_SUBNET_B \
  --security-groups $ALB_SG_ID \
  --scheme internet-facing \
  --type application \
  --ip-address-type ipv4 \
  --region eu-west-1

# Output esperado:
# { "LoadBalancers": [{ "LoadBalancerArn": "arn:aws:elasticloadbalancing:...", "DNSName": "shopapi-alb-123456.eu-west-1.elb.amazonaws.com" }] }

ALB_ARN="arn:aws:elasticloadbalancing:eu-west-1:123456789012:loadbalancer/app/shopapi-alb/abc123"
ALB_DNS="shopapi-alb-123456.eu-west-1.elb.amazonaws.com"

# 2.4 Crear Target Group
aws elbv2 create-target-group \
  --name shopapi-tg \
  --protocol HTTP \
  --port 8080 \
  --vpc-id $VPC_ID \
  --target-type ip \
  --health-check-protocol HTTP \
  --health-check-path /health \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --region eu-west-1

TG_ARN="arn:aws:elasticloadbalancing:eu-west-1:123456789012:targetgroup/shopapi-tg/abc123"

# 2.5 Crear Listener HTTP:80
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN \
  --region eu-west-1
```

#### Paso 3: ECS Service

```bash
# 3.1 Obtener la última revisión de la Task Definition
TASK_DEF_ARN=$(aws ecs describe-task-definition \
  --task-definition shopapi-api \
  --region eu-west-1 \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

# 3.2 Crear el ECS Service
aws ecs create-service \
  --cluster shopapi-cluster \
  --service-name shopapi-api-service \
  --task-definition $TASK_DEF_ARN \
  --desired-count 2 \
  --launch-type FARGATE \
  --platform-version LATEST \
  --network-configuration "awsvpcConfiguration={
    subnets=[$PRIVATE_SUBNET_A,$PRIVATE_SUBNET_B],
    securityGroups=[$TASK_SG_ID],
    assignPublicIp=DISABLED
  }" \
  --load-balancers "targetGroupArn=$TG_ARN,containerName=shopapi-api,containerPort=8080" \
  --health-check-grace-period-seconds 60 \
  --deployment-configuration "maximumPercent=200,minimumHealthyPercent=100,deploymentCircuitBreaker={enable=true,rollback=true}" \
  --region eu-west-1

# Output esperado:
# { "service": { "serviceName": "shopapi-api-service", "status": "ACTIVE", "desiredCount": 2, "runningCount": 0, "pendingCount": 2 } }

# 3.3 Esperar a que el servicio esté estable
aws ecs wait services-stable \
  --cluster shopapi-cluster \
  --services shopapi-api-service \
  --region eu-west-1

# 3.4 Verificar con curl
curl http://$ALB_DNS/health
# Output esperado: {"status":"ok","version":"0.1.0"}

curl http://$ALB_DNS/products
# Output esperado: [{"id":1,"name":"Laptop",...},...]
```

---

## Fase B: Terraform

Ver directorio `terraform/` para la configuración completa.

```bash
cd terraform/

# Inicializar
terraform init

# Planificar (revisar los recursos a crear)
terraform plan -var="account_id=$(aws sts get-caller-identity --query Account --output text)"

# Aplicar
terraform apply -auto-approve

# Obtener el DNS del ALB
terraform output alb_dns_name

# Verificar
curl http://$(terraform output -raw alb_dns_name)/health
```

---

## Demo: Rolling Update

### Concepto: Matematica del Rolling Update

Con la configuracion del ECS Service:

```
desiredCount            = 2
maximumPercent          = 200  →  maximo  4 tasks durante el update
minimumHealthyPercent   = 100  →  minimo  2 tasks siempre saludables
```

Secuencia del rolling update:

```
Estado inicial:    [v1] [v1]          (2 running, 0 pending)
Inicia update:     [v1] [v1] [v2] [v2]  (2 old + 2 new = 4, el maximo)
v2 pasan health:   [v1] [v1] [v2] [v2]  → ALB draining v1
v1 drenadas:             [v2] [v2]      (2 running, stable)
```

El trafico nunca se interrumpe porque `minimumHealthyPercent=100` garantiza
que siempre hay al menos 2 tasks saludables registradas en el Target Group.

### Paso a paso

```bash
# 1. Registrar nueva Task Definition con version 0.2.0
# (usando 04-rolling-update.sh)

# 2. Actualizar el servicio
aws ecs update-service \
  --cluster shopapi-cluster \
  --service shopapi-api-service \
  --task-definition shopapi-api:NUEVA_REVISION \
  --region eu-west-1

# 3. Monitorear el deployment en tiempo real
watch -n 5 'aws ecs describe-services \
  --cluster shopapi-cluster \
  --services shopapi-api-service \
  --region eu-west-1 \
  --query "services[0].deployments[*].{status:status,desired:desiredCount,running:runningCount,pending:pendingCount}"'

# 4. Verificar que el ALB responde sin interrupciones
while true; do
  echo -n "$(date +%H:%M:%S) → "
  curl -s http://$ALB_DNS/health | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"version={d['version']} status={d['status']}\")"
  sleep 2
done
```

### Monitorear eventos del servicio

```bash
aws ecs describe-services \
  --cluster shopapi-cluster \
  --services shopapi-api-service \
  --region eu-west-1 \
  --query 'services[0].events[:10]'
```

---

## Validacion Final

```bash
# Health check
curl -s http://$ALB_DNS/health
# {"status":"ok","version":"0.2.0"}

# Listado de productos
curl -s http://$ALB_DNS/products | python3 -m json.tool

# Crear orden
curl -s -X POST http://$ALB_DNS/orders \
  -H "Content-Type: application/json" \
  -d '{"product_id": 1, "quantity": 2}'

# Metricas
curl -s http://$ALB_DNS/metrics

# Verificar targets del ALB (deben estar HEALTHY)
aws elbv2 describe-target-health \
  --target-group-arn $TG_ARN \
  --region eu-west-1 \
  --query 'TargetHealthDescriptions[*].{ip:Target.Id,port:Target.Port,state:TargetHealth.State}'
```

---

## Troubleshooting

### Escenario 1: Tasks en estado PENDING sin pasar a RUNNING

**Sintomas**: `pendingCount > 0`, `runningCount = 0` durante mas de 5 minutos.

**Causas y soluciones**:

```bash
# Revisar eventos del servicio
aws ecs describe-services \
  --cluster shopapi-cluster \
  --services shopapi-api-service \
  --region eu-west-1 \
  --query 'services[0].events[:5]'

# Revisar tasks stopped (con motivo de fallo)
aws ecs list-tasks \
  --cluster shopapi-cluster \
  --service-name shopapi-api-service \
  --desired-status STOPPED \
  --region eu-west-1

aws ecs describe-tasks \
  --cluster shopapi-cluster \
  --tasks $(aws ecs list-tasks --cluster shopapi-cluster --service-name shopapi-api-service --desired-status STOPPED --query 'taskArns[0]' --output text) \
  --region eu-west-1 \
  --query 'tasks[0].{stoppedReason:stoppedReason,containers:containers[*].{name:name,reason:reason}}'
```

**Causas comunes**:

| Mensaje de error | Causa | Solucion |
|-----------------|-------|----------|
| `ResourceInitializationError: no container instances` | La subnet no tiene IPs disponibles | Verificar CIDR /24 tiene suficientes IPs |
| `CannotPullContainerError` | NAT Gateway no configurado o SG bloquea ECR | Verificar route table privada apunta a NAT GW |
| `Timeout waiting for network interface` | SG de la task muy restrictivo | Verificar outbound del TASK_SG (debe ser 0.0.0.0/0 por defecto) |

```bash
# Verificar route table de subnets privadas
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$PRIVATE_SUBNET_A" \
  --region eu-west-1 \
  --query 'RouteTables[0].Routes'
# Debe incluir: { "DestinationCidrBlock": "0.0.0.0/0", "NatGatewayId": "nat-..." }

# Verificar IPs disponibles en la subnet
aws ec2 describe-subnets \
  --subnet-ids $PRIVATE_SUBNET_A \
  --region eu-west-1 \
  --query 'Subnets[0].AvailableIpAddressCount'
```

---

### Escenario 2: ALB Targets Unhealthy

**Sintomas**: Tasks en RUNNING pero el ALB muestra `unhealthy` en el target group.

```bash
# Ver estado de los targets
aws elbv2 describe-target-health \
  --target-group-arn $TG_ARN \
  --region eu-west-1

# Output con targets unhealthy:
# { "TargetHealth": { "State": "unhealthy", "Reason": "Target.Timeout", "Description": "..." } }
```

**Causas y soluciones**:

1. **Health check grace period insuficiente** — La app tarda en arrancar

```bash
# Aumentar el grace period a 120 segundos
aws ecs update-service \
  --cluster shopapi-cluster \
  --service shopapi-api-service \
  --health-check-grace-period-seconds 120 \
  --region eu-west-1
```

2. **SG de la task no permite trafico desde el ALB**

```bash
# Verificar regla inbound del TASK_SG
aws ec2 describe-security-groups \
  --group-ids $TASK_SG_ID \
  --region eu-west-1 \
  --query 'SecurityGroups[0].IpPermissions'

# Debe incluir: { "FromPort": 8080, "ToPort": 8080, "UserIdGroupPairs": [{ "GroupId": "sg-ALB_SG_ID" }] }

# Si falta, anadir la regla
aws ec2 authorize-security-group-ingress \
  --group-id $TASK_SG_ID \
  --protocol tcp \
  --port 8080 \
  --source-group $ALB_SG_ID \
  --region eu-west-1
```

3. **Health check path incorrecto** — La app usa `/health` no `/`

```bash
# Verificar configuracion del TG
aws elbv2 describe-target-groups \
  --target-group-arns $TG_ARN \
  --region eu-west-1 \
  --query 'TargetGroups[0].{path:HealthCheckPath,port:HealthCheckPort,protocol:HealthCheckProtocol}'
```

---

### Escenario 3: Rolling Update Atascado

**Sintomas**: Nuevo deployment en estado `IN_PROGRESS` por mas de 10 minutos sin progresar.

```bash
# Ver estado de los deployments
aws ecs describe-services \
  --cluster shopapi-cluster \
  --services shopapi-api-service \
  --region eu-west-1 \
  --query 'services[0].deployments'
```

**Causas y soluciones**:

1. **Circuit Breaker activado** — Las nuevas tasks fallan repetidamente

```bash
# Ver si el circuit breaker hizo rollback automatico
aws ecs describe-services \
  --cluster shopapi-cluster \
  --services shopapi-api-service \
  --region eu-west-1 \
  --query 'services[0].deployments[*].{id:id,status:status,failedTasks:failedTasks,rolloutState:rolloutState}'

# Si rolloutState = "FAILED", hubo rollback automatico
# Verificar logs de las tasks fallidas en CloudWatch
aws logs get-log-events \
  --log-group-name /ecs/shopapi-api \
  --log-stream-name ecs/shopapi-api/TASK_ID \
  --region eu-west-1
```

2. **maximumPercent insuficiente** — No hay capacidad para lanzar nuevas tasks

```bash
# Con desiredCount=2 y maximumPercent=100, no puede lanzar tasks nuevas
# antes de terminar las viejas (downtime inevitable)
# Solucionar aumentando maximumPercent:
aws ecs update-service \
  --cluster shopapi-cluster \
  --service shopapi-api-service \
  --deployment-configuration "maximumPercent=200,minimumHealthyPercent=100" \
  --region eu-west-1
```

3. **Forzar nuevo deployment si esta atascado**

```bash
aws ecs update-service \
  --cluster shopapi-cluster \
  --service shopapi-api-service \
  --force-new-deployment \
  --region eu-west-1
```

---

## Limpieza (en orden correcto)

**IMPORTANTE**: La limpieza debe seguir el orden inverso al de creacion para evitar errores de dependencias.

```bash
# Usar el script automatizado:
./cli/99-cleanup.sh

# O manualmente en este orden:

# 1. Escalar el servicio a 0 y eliminarlo
aws ecs update-service \
  --cluster shopapi-cluster \
  --service shopapi-api-service \
  --desired-count 0 \
  --region eu-west-1

aws ecs delete-service \
  --cluster shopapi-cluster \
  --service shopapi-api-service \
  --region eu-west-1

# 2. Eliminar ALB (listener se elimina automaticamente)
aws elbv2 delete-load-balancer \
  --load-balancer-arn $ALB_ARN \
  --region eu-west-1

# Esperar a que se elimine
aws elbv2 wait load-balancers-deleted \
  --load-balancer-arns $ALB_ARN \
  --region eu-west-1

# 3. Eliminar Target Group
aws elbv2 delete-target-group \
  --target-group-arn $TG_ARN \
  --region eu-west-1

# 4. Eliminar NAT Gateway y liberar Elastic IP
aws ec2 delete-nat-gateway \
  --nat-gateway-id $NAT_GW_ID \
  --region eu-west-1

# Esperar a que se elimine (puede tardar 60-90 segundos)
aws ec2 wait nat-gateway-deleted \
  --nat-gateway-ids $NAT_GW_ID \
  --region eu-west-1

aws ec2 release-address \
  --allocation-id $EIP_ALLOC_ID \
  --region eu-west-1

# 5. Detach y eliminar Internet Gateway
aws ec2 detach-internet-gateway \
  --internet-gateway-id $IGW_ID \
  --vpc-id $VPC_ID \
  --region eu-west-1

aws ec2 delete-internet-gateway \
  --internet-gateway-id $IGW_ID \
  --region eu-west-1

# 6. Eliminar subnets
for SUBNET_ID in $PUBLIC_SUBNET_A $PUBLIC_SUBNET_B $PRIVATE_SUBNET_A $PRIVATE_SUBNET_B; do
  aws ec2 delete-subnet --subnet-id $SUBNET_ID --region eu-west-1
done

# 7. Eliminar route tables (no la main)
aws ec2 delete-route-table --route-table-id $RT_PUBLIC_ID --region eu-west-1
aws ec2 delete-route-table --route-table-id $RT_PRIVATE_ID --region eu-west-1

# 8. Eliminar Security Groups (primero tasks, luego alb)
aws ec2 delete-security-group --group-id $TASK_SG_ID --region eu-west-1
aws ec2 delete-security-group --group-id $ALB_SG_ID --region eu-west-1

# 9. Eliminar VPC
aws ec2 delete-vpc --vpc-id $VPC_ID --region eu-west-1
```

---

## Conceptos clave para el examen AWS SAA

### Rolling Update — Matematica esencial

| Parametro               | Valor | Significado |
|------------------------|-------|-------------|
| `desiredCount`          | 2     | Tasks deseadas en estado estable |
| `maximumPercent`        | 200   | Maximo tasks = 2 × 2 = **4** durante el update |
| `minimumHealthyPercent` | 100   | Minimo healthy = 100% × 2 = **2** siempre |

**Pregunta tipo examen**: Con desiredCount=4, maximumPercent=150, minimumHealthyPercent=50:
- Maximo tasks = 4 × 1.5 = **6** (se redondea a 6)
- Minimo healthy = 4 × 0.5 = **2** (puede bajar a 2 durante update)

### Security Group Chaining (encadenamiento de SGs)

En lugar de poner un CIDR de subnet, se referencia el **ID del SG del ALB**:

```
Mala practica:   TASK_SG inbound 8080 from 10.0.0.0/16  (demasiado permisivo)
Buena practica:  TASK_SG inbound 8080 from sg-ALB_SG_ID  (solo el ALB)
```

Ventajas del encadenamiento:
- No hay que actualizar reglas cuando cambian IPs del ALB
- Principio de minimo privilegio
- Funciona con Auto Scaling del ALB

### awsvpc y Elastic Network Interfaces

Con `awsvpc`, **cada task recibe su propia ENI**:

- Limite de ENIs por instancia EC2 (no aplica a Fargate directamente)
- En Fargate: limite de **tareas por subnet** basado en IPs disponibles
- Una subnet /24 tiene 251 IPs utiles → maximo 251 tasks en esa subnet
- Por eso usamos 2 subnets privadas: 502 tasks posibles

### Connection Draining (Deregistration Delay)

Cuando el ALB va a quitar una task del Target Group durante el rolling update:
1. Deja de enviar **nuevas** conexiones a esa task
2. Espera `deregistration_delay` (defecto: 300 segundos) a que las conexiones existentes terminen
3. Luego la task se termina

Para apps sin estado como la ShopAPI se puede reducir a 30-60 segundos:

```bash
aws elbv2 modify-target-group-attributes \
  --target-group-arn $TG_ARN \
  --attributes Key=deregistration_delay.timeout_seconds,Value=60 \
  --region eu-west-1
```

### Deployment Circuit Breaker

Con `deploymentCircuitBreaker` activado:
- Si **mas del 50%** de las tasks lanzadas fallan en arrancar, el deployment se marca como `FAILED`
- Con `rollback=true`, ECS revierte automaticamente a la revision anterior
- Evita que un deployment roto se quede en bucle infinito consumiendo recursos

---

## Costes aproximados del lab

| Recurso      | Precio (eu-west-1)         | Coste lab (2h) |
|--------------|---------------------------|----------------|
| ALB          | $0.008/LCU + $0.0008/hora | ~$0.002        |
| NAT Gateway  | $0.045/hora + $0.045/GB   | ~$0.09         |
| Fargate (x2) | 0.256 vCPU + 0.512 GB     | ~$0.02         |
| **Total**    |                           | **~$0.12**     |

> El NAT Gateway es el componente mas caro. Eliminarlo al finalizar el lab.
