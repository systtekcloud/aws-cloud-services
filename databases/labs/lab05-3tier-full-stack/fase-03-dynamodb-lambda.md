# Fase 03 — DynamoDB Catálogo + Streams → Lambda → SNS

## Objetivo

Crear la tabla DynamoDB para el catálogo de productos y el carrito de compra, habilitar Streams, y construir el flujo event-driven completo: nuevo pedido en DynamoDB → Stream → Lambda → SNS (notificación al cliente).

**Tiempo estimado:** 30-35 minutos

---

## Modelo de datos DynamoDB para el e-commerce

La tabla DynamoDB almacena lo que **no** está en Aurora: el catálogo (muchos atributos, schema flexible) y el carrito (temporal, TTL).

```
┌─────────────────────────────────────────────────────────────────────┐
│  Tabla: ecommerce-catalog                                            │
│                                                                      │
│  PK              SK                Tipo        Datos                 │
│  ─────────────────────────────────────────────────────              │
│  PROD#LIBRO-AWS  METADATA          producto    {nombre, precio, ...} │
│  PROD#LIBRO-AWS  STOCK#eu-west-1   stock       {cantidad: 150}       │
│  PROD#LIBRO-AWS  REVIEW#usr1001    review      {rating: 5, texto}   │
│                                                                      │
│  CART#usr1001    PROD#LIBRO-AWS    carrito     {qty:1, ttl:+1h}     │
│  CART#usr1001    PROD#TECLADO      carrito     {qty:2, ttl:+1h}     │
│                                                                      │
│  GSI1: GSI1PK (categoria) → listar productos por categoría          │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Paso 1 — Crear tabla ecommerce-catalog

```bash
aws dynamodb create-table \
  --table-name ecommerce-catalog \
  --attribute-definitions \
    AttributeName=PK,AttributeType=S \
    AttributeName=SK,AttributeType=S \
    AttributeName=GSI1PK,AttributeType=S \
    AttributeName=GSI1SK,AttributeType=S \
  --key-schema \
    AttributeName=PK,KeyType=HASH \
    AttributeName=SK,KeyType=RANGE \
  --global-secondary-indexes '[{
    "IndexName": "GSI1-categoria",
    "KeySchema": [
      {"AttributeName":"GSI1PK","KeyType":"HASH"},
      {"AttributeName":"GSI1SK","KeyType":"RANGE"}
    ],
    "Projection": {"ProjectionType":"ALL"}
  }]' \
  --billing-mode PAY_PER_REQUEST \
  --stream-specification "StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES" \
  --tags Key=Project,Value=db-labs Key=Lab,Value=lab05 \
  --region eu-west-1

aws dynamodb wait table-exists --table-name ecommerce-catalog --region eu-west-1
```

### Habilitar TTL

```bash
aws dynamodb update-time-to-live \
  --table-name ecommerce-catalog \
  --time-to-live-specification "Enabled=true,AttributeName=ttl" \
  --region eu-west-1
```

---

## Paso 2 — Insertar catálogo de productos

```bash
# Producto: Libro AWS SAA-C03
aws dynamodb put-item --table-name ecommerce-catalog --region eu-west-1 --item '{
  "PK":     {"S":"PROD#LIBRO-AWS"},
  "SK":     {"S":"METADATA"},
  "GSI1PK": {"S":"CAT#libros"},
  "GSI1SK": {"S":"PROD#LIBRO-AWS"},
  "nombre": {"S":"Guía AWS Solutions Architect Associate"},
  "precio": {"N":"89.99"},
  "descripcion": {"S":"Guía completa para el examen SAA-C03"},
  "imagen_url": {"S":"https://example.com/libro-aws.jpg"},
  "tipo":   {"S":"PRODUCTO"}
}'

aws dynamodb put-item --table-name ecommerce-catalog --region eu-west-1 --item '{
  "PK":     {"S":"PROD#LIBRO-AWS"},
  "SK":     {"S":"STOCK#eu-west-1"},
  "cantidad":{"N":"150"},
  "reservado":{"N":"5"},
  "tipo":   {"S":"STOCK"}
}'

# Producto: Teclado mecánico
aws dynamodb put-item --table-name ecommerce-catalog --region eu-west-1 --item '{
  "PK":     {"S":"PROD#TECLADO-MECH"},
  "SK":     {"S":"METADATA"},
  "GSI1PK": {"S":"CAT#hardware"},
  "GSI1SK": {"S":"PROD#TECLADO-MECH"},
  "nombre": {"S":"Teclado Mecánico TKL"},
  "precio": {"N":"149.00"},
  "descripcion": {"S":"Teclado mecánico sin teclado numérico, switches Cherry MX"},
  "tipo":   {"S":"PRODUCTO"}
}'

# Carrito de Ana (TTL: 1 hora)
TTL_1H=$(date -d '+1 hour' +%s)
aws dynamodb put-item --table-name ecommerce-catalog --region eu-west-1 --item "{
  \"PK\":     {\"S\":\"CART#usr1001\"},
  \"SK\":     {\"S\":\"PROD#TECLADO-MECH\"},
  \"cantidad\":{\"N\":\"1\"},
  \"precio_unit\":{\"N\":\"149.00\"},
  \"ttl\":   {\"N\":\"${TTL_1H}\"},
  \"tipo\":  {\"S\":\"CARRITO\"}
}"

echo "Catálogo y carrito insertados"
```

---

## Paso 3 — SNS Topic para notificaciones

```bash
SNS_ARN=$(aws sns create-topic \
  --name ecommerce-pedidos-notif \
  --tags Key=Project,Value=db-labs Key=Lab,Value=lab05 \
  --query 'TopicArn' --output text --region eu-west-1)

echo "SNS ARN: $SNS_ARN"

# Suscribir un email de prueba (opcional)
# aws sns subscribe --topic-arn $SNS_ARN --protocol email \
#   --notification-endpoint tu@email.com --region eu-west-1
```

---

## Paso 4 — Lambda: procesar Stream + notificar via SNS

### IAM Role para Lambda

```bash
LAMBDA_ROLE_ARN=$(aws iam create-role \
  --role-name lambda-catalog-stream-role \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
  }' --query 'Role.Arn' --output text)

aws iam attach-role-policy --role-name lambda-catalog-stream-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaDynamoDBExecutionRole

# Añadir permiso para publicar en SNS
aws iam put-role-policy \
  --role-name lambda-catalog-stream-role \
  --policy-name AllowSNSPublish \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{
      \"Effect\":\"Allow\",
      \"Action\":\"sns:Publish\",
      \"Resource\":\"${SNS_ARN}\"
    }]
  }"

sleep 15
```

### Código de la función Lambda

```python
# lambda_function.py
import json
import logging
import os
import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sns = boto3.client('sns', region_name='eu-west-1')
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', '')

def lambda_handler(event, context):
    """
    Procesa DynamoDB Streams del catálogo ecommerce.
    - Detecta nuevos pedidos (PK=PEDIDO#XXX, SK=METADATA, INSERT)
    - Detecta cambios de estado (MODIFY: estado cambió)
    - Detecta carritos expirados por TTL (REMOVE via DynamoDB service)
    """
    logger.info(f"Procesando {len(event['Records'])} records")

    for record in event['Records']:
        event_name = record['eventName']
        dynamo     = record.get('dynamodb', {})
        new_img    = dynamo.get('NewImage', {})
        old_img    = dynamo.get('OldImage', {})

        pk   = new_img.get('PK', old_img.get('PK', {})).get('S', 'N/A')
        sk   = new_img.get('SK', old_img.get('SK', {})).get('S', 'N/A')
        tipo = new_img.get('tipo', old_img.get('tipo', {})).get('S', 'N/A')

        logger.info(f"[{event_name}] PK={pk} SK={sk} tipo={tipo}")

        # Nuevo pedido insertado
        if event_name == 'INSERT' and pk.startswith('PEDIDO#'):
            usuario_id = new_img.get('usuario_id', {}).get('S', 'N/A')
            total      = new_img.get('total', {}).get('N', '0')
            estado     = new_img.get('estado', {}).get('S', 'N/A')

            mensaje = f"Nuevo pedido {pk} para usuario {usuario_id}: {total}€ — {estado}"
            logger.info(f"  → NOTIFICANDO: {mensaje}")

            if SNS_TOPIC_ARN:
                sns.publish(
                    TopicArn=SNS_TOPIC_ARN,
                    Subject=f"Nuevo pedido: {pk}",
                    Message=json.dumps({
                        "pedido_id": pk,
                        "usuario_id": usuario_id,
                        "total": total,
                        "estado": estado,
                        "evento": "NUEVO_PEDIDO"
                    }, indent=2)
                )

        # Cambio de estado de pedido
        elif event_name == 'MODIFY' and pk.startswith('PEDIDO#'):
            old_estado = old_img.get('estado', {}).get('S', 'N/A')
            new_estado = new_img.get('estado', {}).get('S', 'N/A')

            if old_estado != new_estado:
                logger.info(f"  → Estado cambió: {old_estado} → {new_estado}")
                if SNS_TOPIC_ARN:
                    sns.publish(
                        TopicArn=SNS_TOPIC_ARN,
                        Subject=f"Pedido actualizado: {pk}",
                        Message=json.dumps({
                            "pedido_id": pk,
                            "estado_anterior": old_estado,
                            "estado_nuevo": new_estado,
                            "evento": "CAMBIO_ESTADO"
                        })
                    )

        # Carrito expirado por TTL
        elif event_name == 'REMOVE' and pk.startswith('CART#'):
            identity = record.get('userIdentity', {})
            if identity.get('principalId') == 'dynamodb.amazonaws.com':
                logger.info(f"  → Carrito {pk} expirado por TTL — posible abandono")
                # Aquí podrías enviar un recordatorio al usuario

    return {'statusCode': 200, 'processed': len(event['Records'])}
```

### Desplegar Lambda

```bash
cat > /tmp/lambda_function.py << 'PYEOF'
# [contenido del código de arriba]
PYEOF

cd /tmp && zip -q catalog-stream.zip lambda_function.py

LAMBDA_ARN=$(aws lambda create-function \
  --function-name ecommerce-catalog-stream \
  --runtime python3.12 \
  --role $LAMBDA_ROLE_ARN \
  --handler lambda_function.lambda_handler \
  --zip-file fileb:///tmp/catalog-stream.zip \
  --timeout 60 \
  --environment "Variables={SNS_TOPIC_ARN=${SNS_ARN}}" \
  --tags Project=db-labs,Lab=lab05 \
  --query 'FunctionArn' --output text --region eu-west-1)

aws lambda wait function-active \
  --function-name ecommerce-catalog-stream --region eu-west-1
```

---

## Paso 5 — Event Source Mapping (Stream → Lambda)

```bash
STREAM_ARN=$(aws dynamodb describe-table \
  --table-name ecommerce-catalog \
  --query 'Table.LatestStreamArn' \
  --output text --region eu-west-1)

aws lambda create-event-source-mapping \
  --function-name ecommerce-catalog-stream \
  --event-source-arn $STREAM_ARN \
  --starting-position LATEST \
  --batch-size 10 \
  --region eu-west-1
```

---

## Paso 6 — Probar el flujo completo

```bash
# Insertar un pedido nuevo → debe disparar Lambda → SNS
aws dynamodb put-item --table-name ecommerce-catalog --region eu-west-1 --item '{
  "PK":         {"S":"PEDIDO#ORD-TEST-001"},
  "SK":         {"S":"METADATA"},
  "usuario_id": {"S":"usr1001"},
  "total":      {"N":"238.99"},
  "estado":     {"S":"pendiente"},
  "items":      {"N":"2"},
  "tipo":       {"S":"PEDIDO"}
}'

sleep 20  # Esperar procesamiento

# Ver logs de Lambda
aws logs filter-log-events \
  --log-group-name /aws/lambda/ecommerce-catalog-stream \
  --filter-pattern "NOTIFICANDO" \
  --start-time $(($(date +%s) - 300))000 \
  --query 'events[*].message' --output text --region eu-west-1
# Esperado: "→ NOTIFICANDO: Nuevo pedido PEDIDO#ORD-TEST-001..."
```

---

## ✅ Validaciones

```bash
# 1. Tabla activa con Streams habilitados
aws dynamodb describe-table --table-name ecommerce-catalog \
  --query 'Table.{Status:TableStatus,Stream:StreamSpecification.StreamEnabled}' \
  --output table --region eu-west-1

# 2. Lambda con ESM activo
aws lambda list-event-source-mappings \
  --function-name ecommerce-catalog-stream \
  --query 'EventSourceMappings[0].{State:State,Result:LastProcessingResult}' \
  --output table --region eu-west-1

# 3. Items en la tabla
aws dynamodb scan --table-name ecommerce-catalog \
  --select COUNT --region eu-west-1
```
