# Lab 06.02 — Inspector en ECR (Enhanced Scanning)

> **Coste:** GRATIS durante 30 días de free trial | **Prerrequisito:** Docker instalado localmente

---

## Objetivo

Habilitar Enhanced Scanning en ECR con Amazon Inspector, hacer push de una imagen con vulnerabilidades conocidas, y verificar que Inspector genera findings automáticamente en el push.

---

## Paso 1 — Habilitar Enhanced Scanning en el repositorio ECR

```bash
export AWS_REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Crear repositorio ECR para el lab
aws ecr create-repository \
  --repository-name lab06-inspector-demo \
  --image-scanning-configuration scanOnPush=false \
  --region "$AWS_REGION" 2>/dev/null || echo "Repositorio ya existe"

ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/lab06-inspector-demo"
echo "ECR URI: $ECR_URI"
```

```bash
# Habilitar Enhanced Scanning en ECR via Inspector
# (sobrescribe Basic Scanning del repositorio)
aws inspector2 enable \
  --resource-types ECR \
  --region "$AWS_REGION"

# Configurar Enhanced Scanning para el repositorio
aws ecr put-registry-scanning-configuration \
  --scan-type ENHANCED \
  --rules '[{
    "repositoryFilters": [{
      "filter": "lab06-*",
      "filterType": "WILDCARD"
    }],
    "scanFrequency": "CONTINUOUS_SCAN"
  }]' \
  --region "$AWS_REGION"

echo "Enhanced Scanning configurado para repositorios lab06-*"
```

```bash
# Verificar la configuración
aws ecr get-registry-scanning-configuration \
  --region "$AWS_REGION" \
  --query '{Tipo:scanType,Reglas:rules}' \
  --output json
```

---

## Paso 2 — Construir imagen con vulnerabilidades conocidas

Usamos una imagen base antigua que tiene CVEs conocidos para que Inspector genere findings.

```bash
# Autenticarse en ECR
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin \
  "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Crear Dockerfile con imagen base antigua (vulnerabilidades conocidas)
cat > /tmp/Dockerfile-lab06 <<'DOCKERFILE'
# Imagen base con vulnerabilidades conocidas para demo
FROM python:3.9-slim-bullseye

# Instalar dependencias con versiones vulnerables conocidas
RUN pip install --no-cache-dir \
    requests==2.25.0 \
    Pillow==8.1.0 \
    cryptography==3.2.0

# App simple
COPY --chown=app:app . /app
WORKDIR /app
CMD ["python", "-c", "print('Inspector demo app')"]
DOCKERFILE

# Construir la imagen
docker build -f /tmp/Dockerfile-lab06 -t lab06-inspector-demo:vulnerable /tmp/

echo "Imagen construida: lab06-inspector-demo:vulnerable"
```

---

## Paso 3 — Push y esperar findings

```bash
# Etiquetar y hacer push
docker tag lab06-inspector-demo:vulnerable "${ECR_URI}:vulnerable"
docker push "${ECR_URI}:vulnerable"

echo "Imagen subida a ECR. Inspector empezará a escanear automáticamente..."
echo "Los findings aparecen en 1-5 minutos."
```

```bash
# Verificar que la imagen tiene Enhanced Scanning activo
aws ecr describe-image-scan-findings \
  --repository-name lab06-inspector-demo \
  --image-id imageTag=vulnerable \
  --region "$AWS_REGION" \
  --query '{Estado:imageScanStatus.status,Descripcion:imageScanStatus.description}' \
  --output table 2>/dev/null || echo "Aún sin resultados de escaneo básico (normal con Enhanced)"
```

```bash
# Ver findings via Inspector (Enhanced Scanning)
# Esperar 2-5 minutos y ejecutar:
aws inspector2 list-findings \
  --filter-criteria '{
    "resourceType": [{"comparison": "EQUALS", "value": "AWS_ECR_CONTAINER_IMAGE"}],
    "ecrImageRepositoryName": [{"comparison": "EQUALS", "value": "lab06-inspector-demo"}]
  }' \
  --sort-criteria '{"field": "SEVERITY", "sortOrder": "DESC"}' \
  --region "$AWS_REGION" \
  --query 'findings[].{CVE:packageVulnerabilityDetails.vulnerabilityId,Paquete:packageVulnerabilityDetails.vulnerablePackages[0].name,Version:packageVulnerabilityDetails.vulnerablePackages[0].version,Fix:packageVulnerabilityDetails.vulnerablePackages[0].fixedInVersion,Severidad:severity}' \
  --output table
```

---

## Paso 4 — Comparar Basic Scanning vs Enhanced Scanning

```bash
# Habilitar TAMBIÉN Basic Scanning en otro repositorio para comparar
aws ecr create-repository \
  --repository-name lab06-basic-scan-demo \
  --image-scanning-configuration scanOnPush=true \
  --region "$AWS_REGION" 2>/dev/null || true

# Push de la misma imagen al repositorio con Basic Scanning
docker tag lab06-inspector-demo:vulnerable \
  "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/lab06-basic-scan-demo:vulnerable"
docker push "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/lab06-basic-scan-demo:vulnerable"

echo "Comparar findings en ECR Console:"
echo "  lab06-basic-scan-demo    → Basic Scanning (paquetes SO solo)"
echo "  lab06-inspector-demo     → Enhanced Scanning (SO + dependencias app)"
```

```bash
# Basic Scanning: ver resultados via ECR (no Inspector)
sleep 30
aws ecr describe-image-scan-findings \
  --repository-name lab06-basic-scan-demo \
  --image-id imageTag=vulnerable \
  --region "$AWS_REGION" \
  --query 'imageScanFindings.findings[].{CVE:name,Severidad:severity,Paquete:attributes[?key==`package_name`].value|[0]}' \
  --output table 2>/dev/null || echo "Basic scan aún en progreso..."
```

```
Diferencia esperada en los resultados:
  Basic Scanning  → CVEs en paquetes del SO (libc, openssl del Debian base)
  Enhanced Scanning → Basic + CVEs en requests, Pillow, cryptography (Python libs)

Enhanced Scanning detecta más CVEs porque analiza también las dependencias
de la aplicación (pip packages), no solo los paquetes del sistema operativo.
```

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| ¿Enhanced vs Basic Scanning en ECR? | Enhanced = Inspector (SO + app deps, continuo). Basic = ECR nativo (SO solo, solo en push) |
| ¿Dónde aparecen los findings de Enhanced Scanning? | Inspector Console + Security Hub + EventBridge |
| ¿Se re-escanean imágenes existentes? | **Sí** — Enhanced Scanning re-escanea cuando se publican nuevos CVEs |
| ¿Cómo habilitar Enhanced Scanning? | `aws inspector2 enable --resource-types ECR` + `put-registry-scanning-configuration` |
