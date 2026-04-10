# Lab 05-C: Distributed Map

**Objetivo:** Usar el estado Distributed Map para procesar masivamente objetos de S3 en paralelo. Demostrar concurrency control y toleratedFailurePercentage.

**Tiempo estimado:** 40 min  
**Coste estimado:** <$0.10

---

## ¿Qué es Distributed Map?

El estado `Map` clásico de Step Functions procesa arrays en memoria (máximo 40 items concurrentes). El **Distributed Map** (2022) permite procesar hasta **10.000 ejecuciones paralelas** leyendo items desde S3, un array JSON o un CSV.

```
Distributed Map
  ItemReader: S3 bucket/prefix o CSV o array
      │
      ▼ (lanza hasta maxConcurrency ejecuciones child)
  ┌──────────┬──────────┬──────────┐
  │  Child 1 │  Child 2 │  Child N │  (cada uno procesa un ítem)
  │  Lambda  │  Lambda  │  Lambda  │
  └──────────┴──────────┴──────────┘
      │
      ▼ (espera a que todos terminen)
  ResultWriter: escribe resultados en S3
```

**Casos de uso:**
- Procesar todos los ficheros de un bucket S3 (ETL, migración)
- Enviar emails a 1M usuarios
- Validar millones de registros de una base de datos
- Re-procesar eventos históricos

---

## Paso 1: Preparar datos en S3

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="lab05-distributed-map-$ACCOUNT_ID"

# Crear bucket
aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region eu-west-1 \
  --create-bucket-configuration LocationConstraint=eu-west-1

# Crear 20 ficheros CSV de muestra (simulan registros a procesar)
for i in $(seq -w 1 20); do
  cat > /tmp/records-$i.csv << EOF
id,nombre,email,monto
$i-001,Cliente A$i,a$i@ejemplo.com,100.00
$i-002,Cliente B$i,b$i@ejemplo.com,250.50
$i-003,Cliente C$i,c$i@ejemplo.com,75.25
EOF
  aws s3 cp /tmp/records-$i.csv "s3://$BUCKET/input/batch-$i.csv" --region eu-west-1
done

echo "Subidos 20 ficheros CSV a s3://$BUCKET/input/"
aws s3 ls "s3://$BUCKET/input/" --region eu-west-1
```

## Paso 2: Lambda procesadora de cada ítem

```bash
ROLE_ARN=$(aws iam get-role --role-name lab05-sfn-lambda-role 2>/dev/null --query 'Role.Arn' --output text || \
           aws iam get-role --role-name lab01-lambda-basic-role --query 'Role.Arn' --output text)

cat > /tmp/sfn-map-processor.py << 'EOF'
import json
import csv
import boto3

s3 = boto3.client('s3')

def handler(event, context):
    """
    Recibe: {"bucket": "...", "key": "input/batch-XX.csv"}
    Procesa el CSV y devuelve un resumen
    """
    bucket = event['bucket']
    key = event['key']
    
    # Leer el CSV desde S3
    obj = s3.get_object(Bucket=bucket, Key=key)
    content = obj['Body'].read().decode('utf-8')
    
    reader = csv.DictReader(content.splitlines())
    rows = list(reader)
    
    total = sum(float(r['monto']) for r in rows)
    
    print(f"Procesado {key}: {len(rows)} registros, total={total}")
    
    return {
        'key': key,
        'registros_procesados': len(rows),
        'total_monto': total,
        'status': 'ok'
    }
EOF
cd /tmp && zip sfn-map-processor.zip sfn-map-processor.py

aws lambda create-function \
  --function-name lab05-map-processor \
  --runtime python3.12 \
  --handler sfn-map-processor.handler \
  --role "$ROLE_ARN" \
  --zip-file fileb:///tmp/sfn-map-processor.zip \
  --timeout 30 \
  --region eu-west-1 2>/dev/null || \
aws lambda update-function-code \
  --function-name lab05-map-processor \
  --zip-file fileb:///tmp/sfn-map-processor.zip \
  --region eu-west-1

# Dar permiso a Lambda para leer S3
aws iam attach-role-policy \
  --role-name lab05-sfn-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess 2>/dev/null || \
aws iam attach-role-policy \
  --role-name lab01-lambda-basic-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess 2>/dev/null || true
```

## Paso 3: IAM para Step Functions con Distributed Map

```bash
SFN_ROLE_ARN=$(aws iam get-role --role-name lab05-sfn-role --query 'Role.Arn' --output text 2>/dev/null)

# Añadir permisos para S3 (ItemReader y ResultWriter)
aws iam put-role-policy \
  --role-name lab05-sfn-role \
  --policy-name distributed-map-s3 \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:GetObject\", \"s3:ListBucket\"],
        \"Resource\": [\"arn:aws:s3:::$BUCKET\", \"arn:aws:s3:::$BUCKET/*\"]
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": \"s3:PutObject\",
        \"Resource\": \"arn:aws:s3:::$BUCKET/output/*\"
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": \"states:StartExecution\",
        \"Resource\": \"*\"
      }
    ]
  }"
```

## Paso 4: State machine con Distributed Map

```bash
cat > /tmp/sfn-distributed-map.json << EOF
{
  "Comment": "Lab 05C — Distributed Map: procesar todos los CSVs de S3",
  "StartAt": "ProcesarTodosLosFicheros",
  "States": {
    "ProcesarTodosLosFicheros": {
      "Type": "Map",
      "ItemProcessor": {
        "ProcessorConfig": {
          "Mode": "DISTRIBUTED",
          "ExecutionType": "STANDARD"
        },
        "StartAt": "ProcesarFichero",
        "States": {
          "ProcesarFichero": {
            "Type": "Task",
            "Resource": "arn:aws:lambda:eu-west-1:$ACCOUNT_ID:function:lab05-map-processor",
            "Parameters": {
              "bucket": "$BUCKET",
              "key.$": "$.Key"
            },
            "End": true
          }
        }
      },
      "ItemReader": {
        "Resource": "arn:aws:states:::s3:listObjectsV2",
        "Parameters": {
          "Bucket": "$BUCKET",
          "Prefix": "input/"
        }
      },
      "MaxConcurrency": 5,
      "ToleratedFailurePercentage": 20,
      "ResultWriter": {
        "Resource": "arn:aws:states:::s3:putObject",
        "Parameters": {
          "Bucket": "$BUCKET",
          "Prefix": "output/"
        }
      },
      "End": true
    }
  }
}
EOF

DM_ARN=$(aws stepfunctions create-state-machine \
  --name lab05-distributed-map \
  --definition file:///tmp/sfn-distributed-map.json \
  --role-arn "$SFN_ROLE_ARN" \
  --type STANDARD \
  --region eu-west-1 \
  --query 'stateMachineArn' --output text)

echo "Distributed Map SM: $DM_ARN"
```

## Paso 5: Ejecutar y observar

```bash
# Lanzar la ejecución — procesará los 20 CSVs con MaxConcurrency=5
EXEC_ARN=$(aws stepfunctions start-execution \
  --state-machine-arn "$DM_ARN" \
  --name "dm-run-$(date +%s)" \
  --input '{}' \
  --region eu-west-1 \
  --query 'executionArn' --output text)

echo "Ejecución: $EXEC_ARN"
echo "Observa en consola: cada child execution procesando un CSV"

# Esperar y ver resultado
sleep 60
aws stepfunctions describe-execution \
  --execution-arn "$EXEC_ARN" \
  --region eu-west-1 \
  --query '{Status: status, StopDate: stopDate}'

# Ver resultados escritos en S3
aws s3 ls "s3://$BUCKET/output/" --region eu-west-1
```

## ToleratedFailurePercentage — clave del Distributed Map

```
ToleratedFailurePercentage: 20

Significa: si más del 20% de las child executions fallan,
la ejecución del Map completo falla.

Si menos del 20% fallan, el Map se considera exitoso
(los items fallidos se registran en el ResultWriter).

Útil para: batch processing donde algunos fallos son aceptables
(ej: 1% de emails que rebotan no debe parar el envío a 1M usuarios)
```

## Limpieza

```bash
aws stepfunctions delete-state-machine --state-machine-arn "$DM_ARN" --region eu-west-1
aws lambda delete-function --function-name lab05-map-processor --region eu-west-1 2>/dev/null || true
aws s3 rm "s3://$BUCKET" --recursive --region eu-west-1
aws s3api delete-bucket --bucket "$BUCKET" --region eu-west-1
```
