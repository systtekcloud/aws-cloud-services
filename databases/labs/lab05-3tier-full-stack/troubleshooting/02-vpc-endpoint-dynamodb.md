# Troubleshooting 02 — VPC Endpoint DynamoDB: Tráfico no enruta por el Gateway

## Escenario

La EC2 o Lambda en subnets privadas intenta acceder a DynamoDB y:

1. El tráfico sale por NAT Gateway (coste innecesario, latencia mayor)
2. Las llamadas a DynamoDB fallan con `EndpointResolutionError` o timeout
3. Se creó el VPC Endpoint pero DynamoDB sigue sin ser accesible

---

## Diferencia clave: Gateway vs Interface Endpoint

| Tipo | DynamoDB | S3 | Coste |
|------|----------|----|-------|
| **Gateway Endpoint** | ✅ | ✅ | **Gratis** |
| Interface Endpoint | No nativo | ✅ | ~0.01 USD/h por AZ |

> Para DynamoDB, **siempre usar Gateway Endpoint**. Es gratuito y más eficiente que Interface.

---

## Diagnóstico

### Paso 1: Verificar que el VPC Endpoint existe

```bash
aws ec2 describe-vpc-endpoints \
  --filters \
    "Name=vpc-id,Values=vpc-lab05xxx" \
    "Name=service-name,Values=com.amazonaws.eu-west-1.dynamodb" \
  --query 'VpcEndpoints[*].{Id:VpcEndpointId,State:State,Type:VpcEndpointType}' \
  --output table --region eu-west-1
```

Si no aparece ningún resultado → el endpoint no existe.

### Paso 2: Verificar que el endpoint está asociado a las Route Tables correctas

```bash
ENDPOINT_ID="vpce-xxxxxxxxx"

aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids $ENDPOINT_ID \
  --query 'VpcEndpoints[0].RouteTableIds' \
  --output json --region eu-west-1
```

Deben aparecer las Route Tables de las subnets **donde vive la EC2/Lambda** (private-app y private-db).

### Paso 3: Verificar la route table de la subnet

```bash
RT_ID="rtb-xxxxxxxxx"  # Route table de la subnet privada

aws ec2 describe-route-tables \
  --route-table-ids $RT_ID \
  --query 'RouteTables[0].Routes[?contains(DestinationPrefixListId, `pl-`)]' \
  --output json --region eu-west-1
```

La ruta al Gateway Endpoint aparece como destino un **Prefix List** (`pl-xxxxxxxx`), no como CIDR.

### Paso 4: Confirmar si el tráfico pasa por NAT o por el Endpoint

```bash
# Desde la EC2, verificar la IP de destino que resuelve DynamoDB
curl -s https://dynamodb.eu-west-1.amazonaws.com | head -c 100

# O con traceroute
traceroute dynamodb.eu-west-1.amazonaws.com
# Si sale por NAT → verás la IP del NAT Gateway
# Si sale por el endpoint → el salto es directo (interno al backbone AWS)
```

---

## Causas y soluciones

### Causa 1 — Endpoint creado pero no asociado a la Route Table de la subnet

Esta es la causa más frecuente. El Gateway Endpoint modifica las Route Tables para añadir la ruta al Prefix List de DynamoDB. Si la Route Table no está en la lista del endpoint, el tráfico no usa el endpoint.

**Fix:**

```bash
VPC_ID="vpc-lab05xxx"
ENDPOINT_ID=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" \
    "Name=service-name,Values=com.amazonaws.eu-west-1.dynamodb" \
  --query 'VpcEndpoints[0].VpcEndpointId' --output text --region eu-west-1)

# Obtener IDs de las route tables de las subnets privadas
RT_APP=$(aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=rt-private-app-lab05" \
  --query 'RouteTables[0].RouteTableId' --output text --region eu-west-1)

RT_DB=$(aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=rt-private-db-lab05" \
  --query 'RouteTables[0].RouteTableId' --output text --region eu-west-1)

# Asociar el endpoint a ambas route tables
aws ec2 modify-vpc-endpoint \
  --vpc-endpoint-id $ENDPOINT_ID \
  --add-route-table-ids $RT_APP $RT_DB \
  --region eu-west-1
```

**Verificación:**

```bash
aws ec2 describe-route-tables \
  --route-table-ids $RT_APP \
  --query 'RouteTables[0].Routes[?contains(DestinationPrefixListId, `pl-`)]' \
  --output table --region eu-west-1
# Debe aparecer la ruta con GatewayEndpoint como destino
```

### Causa 2 — VPC Endpoint Policy demasiado restrictiva

Por defecto la policy del endpoint es `Allow: *` (acceso total). Si se personalizó, puede estar bloqueando operaciones.

```bash
# Ver la policy del endpoint
aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids $ENDPOINT_ID \
  --query 'VpcEndpoints[0].PolicyDocument' --output text --region eu-west-1 | python3 -m json.tool
```

Si la policy restringe recursos o acciones, ampliarla o restaurar la policy por defecto:

```bash
aws ec2 modify-vpc-endpoint \
  --vpc-endpoint-id $ENDPOINT_ID \
  --policy-document '{"Statement":[{"Effect":"Allow","Principal":"*","Action":"*","Resource":"*"}]}' \
  --region eu-west-1
```

### Causa 3 — EC2/Lambda usa un endpoint URL explícito apuntando fuera de la VPC

Si el código especifica `endpoint_url` explícitamente:

```python
# ❌ MAL: fuerza tráfico fuera de la VPC
dynamodb = boto3.client("dynamodb",
    endpoint_url="https://dynamodb.us-east-1.amazonaws.com",
    region_name="eu-west-1")

# ✅ BIEN: boto3 usa automáticamente el VPC endpoint si existe
dynamodb = boto3.client("dynamodb", region_name="eu-west-1")
```

El SDK de AWS resuelve automáticamente el endpoint correcto si el VPC Gateway Endpoint está configurado.

### Causa 4 — IAM no permite acceso a DynamoDB

El VPC Endpoint controla el enrutamiento de red, pero IAM controla el acceso a la API.

```bash
# Error típico sin permisos IAM:
# "An error occurred (AccessDeniedException) when calling the PutItem operation"

# Verificar los permisos del rol EC2
EC2_ROLE=$(aws ec2 describe-instances \
  --instance-ids $EC2_ID \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
  --output text --region eu-west-1)
echo "EC2 Role ARN: $EC2_ROLE"

# Simular acción DynamoDB
aws iam simulate-principal-policy \
  --policy-source-arn "$EC2_ROLE" \
  --action-names "dynamodb:PutItem" \
  --resource-arns "arn:aws:dynamodb:eu-west-1:ACCOUNT:table/ecommerce-catalog"
```

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|----------|-----------|
| ¿Tipo de endpoint para DynamoDB? | **Gateway Endpoint** (no Interface) |
| ¿Coste del Gateway Endpoint? | **Gratis** |
| ¿Cómo se configura en la red? | Se añade una ruta en las Route Tables seleccionadas |
| ¿Afecta al código de la app? | No — boto3/SDK lo usa automáticamente |
| ¿Funciona con Lambda en VPC? | Sí, si la Lambda está en una subnet con la RT asociada |
| ¿Se necesita SG en el Gateway Endpoint? | No — los Gateway Endpoints no tienen SG (solo Interface Endpoints) |
| ¿DynamoDB tiene IP pública o privada? | DynamoDB es un servicio regional; con el endpoint el tráfico nunca sale de AWS |

> **Diferencia clave para el examen:** Gateway Endpoint (DynamoDB, S3) → añade ruta en Route Table.
> Interface Endpoint (todos los demás) → crea ENI en subnet con IP privada, sí tiene SG.
