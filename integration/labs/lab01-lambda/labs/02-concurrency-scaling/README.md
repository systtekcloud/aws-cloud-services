# Lab 01-B: Concurrencia y Escalado

**Objetivo:** Entender cómo Lambda escala horizontalmente, cómo configurar reserved y provisioned concurrency, y cómo medir el impacto real del cold start en p99 de latencia.

**Tiempo estimado:** 60 min  
**Coste estimado:** <$1 (provisioned concurrency cobra por hora)  
**Región:** eu-west-1

---

## Prereqs

- Completado [01-fundamentos](../01-fundamentos/)
- Función `lab01-fundamentos` activa

---

## Concepto previo: ¿Cómo escala Lambda?

```
Tráfico normal:
  Request 1 → Entorno A (warm)
  Request 2 → Entorno B (warm)
  Request 3 → Entorno A (warm, liberado por request 1)

Burst de tráfico:
  1000 requests simultáneas →
    └─ Lambda crea hasta 1000 entornos (burst limit regional)
       Cada entorno nuevo = cold start para esa invocación

Burst limit inicial (eu-west-1): 3000 invocaciones/min
  → Después escala a 500 nuevos entornos/min hasta el límite de cuenta (1000 default)
```

---

## Paso 1: Observar el comportamiento sin límite de concurrencia

```bash
# 1.1 Función de prueba con sleep para simular trabajo real
cat > /tmp/lambda-concurrency/handler.py << 'EOF'
import time
import json
import os

def handler(event, context):
    duration = event.get('duration_ms', 500)
    time.sleep(duration / 1000)
    return {
        'statusCode': 200,
        'duration_ms': duration,
        'request_id': context.aws_request_id
    }
EOF

mkdir -p /tmp/lambda-concurrency
cat > /tmp/lambda-concurrency/handler.py << 'EOF'
import time
import json

def handler(event, context):
    duration = event.get('duration_ms', 500)
    time.sleep(duration / 1000)
    return {
        'statusCode': 200,
        'duration_ms': duration,
        'request_id': context.aws_request_id
    }
EOF

cd /tmp/lambda-concurrency && zip function.zip handler.py

ROLE_ARN=$(aws iam get-role --role-name lab01-lambda-basic-role --query 'Role.Arn' --output text)

aws lambda create-function \
  --function-name lab01-concurrency-test \
  --runtime python3.12 \
  --handler handler.handler \
  --role "$ROLE_ARN" \
  --zip-file fileb:///tmp/lambda-concurrency/function.zip \
  --timeout 30 \
  --memory-size 128 \
  --region eu-west-1

# 1.2 Invocar en paralelo (10 invocaciones simultáneas) para ver concurrencia
for i in {1..10}; do
  aws lambda invoke \
    --function-name lab01-concurrency-test \
    --payload '{"duration_ms": 2000}' \
    --cli-binary-format raw-in-base64-out \
    --region eu-west-1 \
    /tmp/out-$i.json &
done
wait
echo "10 invocaciones concurrentes completadas"

# 1.3 Ver la métrica de concurrencia en CloudWatch
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name ConcurrentExecutions \
  --dimensions Name=FunctionName,Value=lab01-concurrency-test \
  --start-time "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
  --period 60 \
  --statistics Maximum \
  --region eu-west-1
```

---

## Paso 2: Reserved Concurrency — limitar una función

Reserved concurrency hace dos cosas a la vez:
1. **Garantiza** que esta función siempre tiene N slots disponibles (los "reserva" del pool de cuenta)
2. **Limita** que esta función nunca use más de N slots (throttle si supera)

```bash
# 2.1 Poner reserved concurrency = 2 (máximo 2 invocaciones simultáneas)
aws lambda put-function-concurrency \
  --function-name lab01-concurrency-test \
  --reserved-concurrent-executions 2 \
  --region eu-west-1

# 2.2 Intentar 5 invocaciones simultáneas
for i in {1..5}; do
  aws lambda invoke \
    --function-name lab01-concurrency-test \
    --payload '{"duration_ms": 3000}' \
    --cli-binary-format raw-in-base64-out \
    --region eu-west-1 \
    /tmp/throttle-$i.json 2>&1 &
done
wait

# 2.3 Verificar errores de throttling
for i in {1..5}; do
  echo "Invocación $i:"
  cat /tmp/throttle-$i.json
done
# Verás: {"errorMessage":"Rate Exceeded","errorType":"TooManyRequestsException"}

# 2.4 Quitar el límite de concurrencia
aws lambda delete-function-concurrency \
  --function-name lab01-concurrency-test \
  --region eu-west-1
```

**Caso de uso de reserved concurrency:**
- Función que llama a una DB con 20 conexiones máx → reserved = 15 (deja margen)
- Función de bajo priority → reserved = 10 (evita que consuma todo el pool)

---

## Paso 3: Provisioned Concurrency — eliminar cold start

Provisioned Concurrency pre-inicializa N execution environments. Estos entornos ya han ejecutado el init phase, están calientes, y responden sin cold start.

```bash
# 3.1 Función con cold start artificial (simula carga de modelo ML)
cat > /tmp/lambda-provisioned/handler.py << 'EOF'
import json
import time
import os

# Código de inicialización (global scope = init phase)
# Este código SOLO se ejecuta en cold start
print("INIT: cargando configuración...")
time.sleep(2)  # Simula cargar un modelo de 2 segundos
GLOBAL_CONFIG = {"model_loaded": True, "version": "1.0"}
print("INIT: configuración cargada")

def handler(event, context):
    # Este código se ejecuta en CADA invocación
    return {
        'statusCode': 200,
        'model_loaded': GLOBAL_CONFIG['model_loaded'],
        'request_id': context.aws_request_id
    }
EOF

mkdir -p /tmp/lambda-provisioned
cp /tmp/lambda-provisioned/handler.py /tmp/lambda-provisioned/handler.py 2>/dev/null || true
cat > /tmp/lambda-provisioned/handler.py << 'EOF'
import json, time

print("INIT: cargando modelo (2 segundos)...")
time.sleep(2)
MODEL = {"loaded": True}
print("INIT: modelo cargado")

def handler(event, context):
    return {'statusCode': 200, 'model_loaded': MODEL['loaded']}
EOF

cd /tmp/lambda-provisioned && zip function.zip handler.py

ROLE_ARN=$(aws iam get-role --role-name lab01-lambda-basic-role --query 'Role.Arn' --output text)

aws lambda create-function \
  --function-name lab01-provisioned-test \
  --runtime python3.12 \
  --handler handler.handler \
  --role "$ROLE_ARN" \
  --zip-file fileb:///tmp/lambda-provisioned/function.zip \
  --timeout 30 \
  --memory-size 256 \
  --region eu-west-1

# 3.2 Medir cold start SIN provisioned concurrency
echo "=== SIN Provisioned Concurrency ==="
time aws lambda invoke \
  --function-name lab01-provisioned-test \
  --payload '{}' \
  --cli-binary-format raw-in-base64-out \
  --region eu-west-1 \
  /tmp/cold-start-out.json
# Primera invocación: verás ~2.2s (2s init + 0.2s handler)

# 3.3 Publicar una versión (provisioned concurrency requiere versión o alias)
VERSION=$(aws lambda publish-version \
  --function-name lab01-provisioned-test \
  --region eu-west-1 \
  --query 'Version' \
  --output text)
echo "Versión publicada: $VERSION"

# 3.4 Crear alias 'live' apuntando a la versión
aws lambda create-alias \
  --function-name lab01-provisioned-test \
  --name live \
  --function-version "$VERSION" \
  --region eu-west-1

# 3.5 Activar Provisioned Concurrency en el alias
aws lambda put-provisioned-concurrency-config \
  --function-name lab01-provisioned-test \
  --qualifier live \
  --provisioned-concurrent-executions 2 \
  --region eu-west-1

# 3.6 Esperar a que los entornos estén listos (Status = Ready)
echo "Esperando que Provisioned Concurrency esté lista..."
aws lambda wait function-updated --function-name lab01-provisioned-test --region eu-west-1
sleep 30  # Tiempo para que se inicialicen los entornos

aws lambda get-provisioned-concurrency-config \
  --function-name lab01-provisioned-test \
  --qualifier live \
  --region eu-west-1

# 3.7 Medir latencia CON provisioned concurrency (usando el alias)
echo "=== CON Provisioned Concurrency (alias 'live') ==="
time aws lambda invoke \
  --function-name "lab01-provisioned-test:live" \
  --payload '{}' \
  --cli-binary-format raw-in-base64-out \
  --region eu-west-1 \
  /tmp/warm-out.json
# Debería ser <100ms — el init ya ocurrió

# 3.8 Limpiar provisioned concurrency
aws lambda delete-provisioned-concurrency-config \
  --function-name lab01-provisioned-test \
  --qualifier live \
  --region eu-west-1
```

---

## Paso 4: SnapStart (Java — concepto)

SnapStart es específico de Java 11+ y Java 17 runtimes. Funciona creando un snapshot del entorno después del init phase, y restaurando ese snapshot en cada cold start en lugar de re-ejecutar el init.

```
Sin SnapStart:
  Cold start = Download JAR + JVM boot + Spring init + tu código de init
  Total: 3-10 segundos en Spring Boot

Con SnapStart:
  Cold start = Restore snapshot + tu código de init
  Total: <1 segundo (JVM ya inicializada en el snapshot)
```

**Limitaciones:**
- Solo Java 11 y Java 17 managed runtimes
- El código de init debe ser idempotente (se ejecuta una vez para el snapshot, puede ejecutarse de nuevo en restore)
- No compatible con `RDS IAM auth` directamente en init (la conexión no sobrevive al snapshot)

**Para habilitarlo:**
```bash
aws lambda update-function-configuration \
  --function-name mi-funcion-java \
  --snap-start ApplyOn=PublishedVersions \
  --region eu-west-1
```

---

## Paso 5: Lambda Power Tuning

Lambda Power Tuning es una state machine de Step Functions (open source) que prueba tu función con múltiples configuraciones de memoria y encuentra el punto óptimo coste/rendimiento.

```
Configuraciones testadas: 128, 256, 512, 1024, 2048, 3008 MB
  │
  ▼ (invoca tu función N veces con cada configuración)
  │
  ▼ (calcula: coste por invocación vs latencia promedio)
  │
  ▼ Resultado: gráfico Pareto de coste vs velocidad
```

**Por qué importa:** Lambda asigna CPU proporcional a la memoria. Una función de 128 MB tiene 1/16 de CPU vs una de 3008 MB. Para funciones CPU-bound (procesamiento de imágenes, criptografía), aumentar memoria puede reducir coste total al terminar más rápido.

```bash
# Instalar via SAR (Serverless Application Repository)
aws serverlessrepo create-cloud-formation-template \
  --application-id arn:aws:serverlessrepo:us-east-1:451282441545:applications/aws-lambda-power-tuning \
  --semantic-version 4.3.4

# O via SAM CLI:
# sam deploy --guided (usando template de aws-lambda-power-tuning)
```

---

## Resumen

| Concepto | Efecto | Cuándo |
|----------|--------|--------|
| Sin configuración | Escala infinito, cold starts posibles | La mayoría de casos |
| Reserved Concurrency | Limita y garantiza slots | Proteger downstream, priorización |
| Provisioned Concurrency | Elimina cold start | P99 < 100ms requisito |
| SnapStart (Java) | Reduce init de 10s a <1s | Apps Java con Spring Boot |
| Power Tuning | Optimiza memoria vs coste | Funciones CPU-bound |

---

## Siguiente sub-lab

[03-layers-extensions →](../03-layers-extensions/)
