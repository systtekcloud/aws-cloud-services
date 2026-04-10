# Lab 01-C: Layers y Extensions

**Objetivo:** Crear y publicar Lambda Layers para compartir dependencias entre funciones. Entender Lambda Extensions y custom runtimes.

**Tiempo estimado:** 45 min  
**Coste estimado:** $0  
**Región:** eu-west-1

---

## Parte A: Lambda Layers

### ¿Qué problema resuelven?

Sin layers: cada función empaqueta sus dependencias. Si 10 funciones usan `pandas`, 10 ZIPs contienen pandas (180 MB × 10 = 1.8 GB desplegados).

Con layers: pandas está en un layer compartido. Las funciones referencian el layer. Un solo despliegue de 180 MB.

```
Función ZIP (solo tu código, ~10 KB)
    + Layer 1 (pandas + numpy, 180 MB)  ← montado en /opt/python/
    + Layer 2 (librerías internas, 5 MB)
    ─────────────────────────────────────
    Runtime ve: /opt/python/lib/python3.12/site-packages/{pandas,numpy,...}
```

---

### Paso 1: Crear layer de dependencias Python

```bash
# 1.1 Estructura de un layer Python
# Lambda busca dependencias en /opt/python/ y /opt/python/lib/python3.12/site-packages/
mkdir -p /tmp/layer-requests/python

# 1.2 Instalar dependencias en el directorio del layer
pip3 install requests --target /tmp/layer-requests/python/

# 1.3 Verificar estructura
ls /tmp/layer-requests/python/
# requests/  requests-2.x.x.dist-info/  certifi/  charset_normalizer/  ...

# 1.4 Empaquetar
cd /tmp/layer-requests
zip -r requests-layer.zip python/

# Verificar tamaño
du -sh requests-layer.zip

# 1.5 Publicar el layer
LAYER_ARN=$(aws lambda publish-layer-version \
  --layer-name lab01-requests-layer \
  --description "requests library for lab01" \
  --zip-file fileb:///tmp/layer-requests/requests-layer.zip \
  --compatible-runtimes python3.12 python3.11 \
  --region eu-west-1 \
  --query 'LayerVersionArn' \
  --output text)

echo "Layer ARN: $LAYER_ARN"
```

### Paso 2: Función que usa el layer

```bash
# 2.1 Código que usa requests (no incluida en el ZIP)
cat > /tmp/lambda-with-layer/handler.py << 'EOF'
import json
import requests  # viene del layer, no del ZIP

def handler(event, context):
    # Llamada HTTP usando requests del layer
    response = requests.get('https://httpbin.org/json', timeout=5)
    return {
        'statusCode': 200,
        'body': json.dumps({
            'http_status': response.status_code,
            'data': response.json()
        })
    }
EOF

mkdir -p /tmp/lambda-with-layer
cat > /tmp/lambda-with-layer/handler.py << 'EOF'
import json
import requests

def handler(event, context):
    r = requests.get('https://httpbin.org/uuid', timeout=5)
    return {'statusCode': 200, 'uuid': r.json()['uuid']}
EOF

cd /tmp/lambda-with-layer && zip function.zip handler.py

ROLE_ARN=$(aws iam get-role --role-name lab01-lambda-basic-role --query 'Role.Arn' --output text)

# 2.2 Crear función con layer adjunto
aws lambda create-function \
  --function-name lab01-with-layer \
  --runtime python3.12 \
  --handler handler.handler \
  --role "$ROLE_ARN" \
  --zip-file fileb:///tmp/lambda-with-layer/function.zip \
  --layers "$LAYER_ARN" \
  --timeout 15 \
  --memory-size 128 \
  --region eu-west-1

# 2.3 Invocar y verificar
aws lambda invoke \
  --function-name lab01-with-layer \
  --payload '{}' \
  --cli-binary-format raw-in-base64-out \
  --region eu-west-1 \
  /tmp/layer-out.json

cat /tmp/layer-out.json
```

### Paso 3: Versionar y actualizar layers

```bash
# 3.1 Publicar versión 2 del layer (por ejemplo, requests 2.32)
pip3 install "requests==2.32.0" --target /tmp/layer-requests-v2/python/
cd /tmp/layer-requests-v2 && zip -r requests-layer-v2.zip python/

LAYER_ARN_V2=$(aws lambda publish-layer-version \
  --layer-name lab01-requests-layer \
  --description "requests 2.32.0" \
  --zip-file fileb:///tmp/layer-requests-v2/requests-layer-v2.zip \
  --compatible-runtimes python3.12 \
  --region eu-west-1 \
  --query 'LayerVersionArn' \
  --output text)

# 3.2 Actualizar función al layer v2
aws lambda update-function-configuration \
  --function-name lab01-with-layer \
  --layers "$LAYER_ARN_V2" \
  --region eu-west-1

# 3.3 Listar versiones del layer
aws lambda list-layer-versions \
  --layer-name lab01-requests-layer \
  --region eu-west-1 \
  --query 'LayerVersions[*].[Version,Description,CreatedDate]'
```

---

## Parte B: Lambda Extensions

Las Extensions son procesos que corren **dentro del execution environment** de Lambda, en paralelo con el handler. Se usan para:

- Agentes de monitoring (Datadog, Dynatrace, New Relic)
- Agentes de seguridad (Aqua, Lacework)
- Flush de métricas/logs antes del freeze

```
Execution Environment
├── Runtime (Python/Node/...)
│     └── Tu handler()
└── Extension process (ej: Datadog agent)
      ├── Recibe eventos: Init, Invoke, Shutdown
      └── Accede a /tmp/, variables de entorno, network
```

### Tipos de extensions

| Tipo | Ejecución | Acceso |
|------|-----------|--------|
| Internal | Dentro del runtime process (via wrapper scripts) | Variables de entorno del runtime |
| External | Proceso separado en el entorno | Sistema de ficheros, red, Lambda API |

### Ciclo de vida con extension

```
INIT phase:
  1. Lambda inicia extension
  2. Extension registra en Extensions API (RegisterExtension)
  3. Lambda inicia runtime
  4. Extension recibe NextEvent → espera

INVOKE phase:
  1. Lambda invoca handler()
  2. Handler termina
  3. Extension recibe Invoke event → hace su trabajo
  4. Extension llama NextEvent → señaliza que terminó

SHUTDOWN phase:
  1. Lambda envía Shutdown a extension
  2. Extension hace cleanup (flush métricas)
  3. Extension termina
```

### Ejemplo: extension mínima en bash

```bash
# /opt/extensions/my-extension (ejecutable)
#!/bin/bash

LAMBDA_EXTENSION_NAME="my-extension"

# Registrar la extension
curl -s -X POST \
  "http://${AWS_LAMBDA_RUNTIME_API}/2020-01-01/extension/register" \
  -H "Lambda-Extension-Name: ${LAMBDA_EXTENSION_NAME}" \
  -d '{"events": ["INVOKE", "SHUTDOWN"]}'

# Loop de eventos
while true; do
  EVENT=$(curl -s \
    "http://${AWS_LAMBDA_RUNTIME_API}/2020-01-01/extension/event/next" \
    -H "Lambda-Extension-Identifier: ${EXTENSION_ID}")
  
  EVENT_TYPE=$(echo "$EVENT" | python3 -c "import sys,json; print(json.load(sys.stdin)['eventType'])")
  
  case "$EVENT_TYPE" in
    INVOKE)
      echo "Extension: invocación completada, flushing métricas..."
      # Aquí irías tus métricas a tu sistema de monitoring
      ;;
    SHUTDOWN)
      echo "Extension: shutdown, limpiando..."
      exit 0
      ;;
  esac
done
```

---

## Parte C: Custom Runtime

Un custom runtime permite ejecutar cualquier lenguaje en Lambda implementando el Runtime API.

```
bootstrap (ejecutable en /var/runtime/ o /opt/)
  │
  ├── GET /runtime/invocation/next        ← esperar próximo evento
  ├── [ejecutar tu handler]
  └── POST /runtime/invocation/{id}/response  ← enviar respuesta
```

### Custom runtime mínimo en bash

```bash
#!/bin/bash
# bootstrap — ejecutable, en raíz del ZIP

while true; do
  # Obtener próxima invocación
  RESPONSE=$(curl -s -D /tmp/headers.txt \
    "http://${AWS_LAMBDA_RUNTIME_API}/2018-06-01/runtime/invocation/next")
  
  REQUEST_ID=$(grep -i "Lambda-Runtime-Aws-Request-Id" /tmp/headers.txt | tr -d '[:space:]' | cut -d: -f2)
  
  # Ejecutar handler (en bash puro)
  RESULT="{\"message\": \"Hello from bash runtime\", \"event\": $RESPONSE}"
  
  # Enviar respuesta
  curl -s -X POST \
    "http://${AWS_LAMBDA_RUNTIME_API}/2018-06-01/runtime/invocation/${REQUEST_ID}/response" \
    -d "$RESULT"
done
```

```bash
# Desplegar custom runtime
chmod +x /tmp/custom-runtime/bootstrap
cd /tmp/custom-runtime && zip runtime.zip bootstrap

aws lambda create-function \
  --function-name lab01-custom-runtime \
  --runtime provided.al2023 \
  --handler bootstrap \
  --role "$ROLE_ARN" \
  --zip-file fileb:///tmp/custom-runtime/runtime.zip \
  --region eu-west-1
```

---

## Siguiente sub-lab

[04-lambda-destinations →](../04-lambda-destinations/)
