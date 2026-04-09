# Lab 01 — OpenSearch: indexar documentos y queries full-text

> **Duración estimada:** 30 minutos | **Coste estimado:** ~$0.50 (t3.small.search × 1h)
> ⚠️ **Eliminar el dominio al terminar** — ver sección de limpieza.

---

## Objetivo

Crear un dominio OpenSearch, indexar documentos JSON de logs de aplicación via REST API, ejecutar queries full-text y agregaciones, y abrir OpenSearch Dashboards para crear una visualización básica.

---

## Paso 1: Crear dominio OpenSearch

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
MY_IP=$(curl -s https://checkip.amazonaws.com)

echo "Tu IP pública: $MY_IP (se usará en la access policy)"

# Access policy: permite acceso desde tu IP
cat > /tmp/os-access-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"AWS": "*"},
    "Action": "es:*",
    "Resource": "arn:aws:es:$REGION:${ACCOUNT_ID}:domain/lab07-opensearch/*",
    "Condition": {
      "IpAddress": {
        "aws:SourceIp": "$MY_IP/32"
      }
    }
  }]
}
EOF

aws opensearch create-domain \
  --domain-name lab07-opensearch \
  --engine-version "OpenSearch_2.11" \
  --cluster-config "{
    \"InstanceType\": \"t3.small.search\",
    \"InstanceCount\": 1,
    \"DedicatedMasterEnabled\": false,
    \"ZoneAwarenessEnabled\": false
  }" \
  --ebs-options "{
    \"EBSEnabled\": true,
    \"VolumeType\": \"gp3\",
    \"VolumeSize\": 10
  }" \
  --access-policies "$(cat /tmp/os-access-policy.json)" \
  --node-to-node-encryption-options '{"Enabled": true}' \
  --encryption-at-rest-options '{"Enabled": true}' \
  --domain-endpoint-options '{"EnforceHTTPS": true}' \
  --advanced-security-options "{
    \"Enabled\": true,
    \"InternalUserDatabaseEnabled\": true,
    \"MasterUserOptions\": {
      \"MasterUserName\": \"admin\",
      \"MasterUserPassword\": \"Lab07Admin#2024\"
    }
  }" \
  --region "$REGION"

echo "Dominio en creación. Esto tarda 10-15 minutos..."
echo "Puedes seguir el estado con:"
echo "  aws opensearch describe-domain --domain-name lab07-opensearch --region $REGION --query 'DomainStatus.Processing'"
```

---

## Paso 2: Esperar y obtener el endpoint

```bash
REGION="eu-west-1"

echo "Esperando que el dominio esté activo (~10-15 min)..."
while true; do
  PROCESSING=$(aws opensearch describe-domain \
    --domain-name lab07-opensearch \
    --region "$REGION" \
    --query 'DomainStatus.Processing' \
    --output text)
  echo "$(date -u +%H:%M:%S) Processing: $PROCESSING"
  [[ "$PROCESSING" == "False" ]] && break
  sleep 30
done

ENDPOINT=$(aws opensearch describe-domain \
  --domain-name lab07-opensearch \
  --region "$REGION" \
  --query 'DomainStatus.Endpoint' \
  --output text)

echo ""
echo "Dominio activo."
echo "Endpoint:   https://$ENDPOINT"
echo "Dashboards: https://$ENDPOINT/_dashboards"
echo "Usuario:    admin"
echo "Password:   Lab07Admin#2024"
export OS_ENDPOINT="https://$ENDPOINT"
```

---

## Paso 3: Indexar documentos via REST API

OpenSearch expone una REST API estándar. Los documentos se indexan con `PUT` o `POST`.

```bash
OS_ENDPOINT=$(aws opensearch describe-domain \
  --domain-name lab07-opensearch \
  --region eu-west-1 \
  --query 'DomainStatus.Endpoint' \
  --output text | xargs -I{} echo "https://{}")

AUTH="admin:Lab07Admin#2024"

# Crear índice con mapping explícito (mejora la búsqueda)
curl -s -u "$AUTH" -X PUT "$OS_ENDPOINT/app-logs" \
  -H "Content-Type: application/json" \
  -d '{
    "mappings": {
      "properties": {
        "timestamp":  {"type": "date"},
        "level":      {"type": "keyword"},
        "service":    {"type": "keyword"},
        "message":    {"type": "text"},
        "duration_ms":{"type": "integer"},
        "status_code":{"type": "integer"},
        "path":       {"type": "keyword"},
        "user_id":    {"type": "keyword"}
      }
    },
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 0
    }
  }' | jq '.'

# Indexar documentos de log de aplicación
DOCS=(
  '{"timestamp":"2024-01-15T10:00:00Z","level":"INFO","service":"api-gateway","message":"Request received GET /products","duration_ms":45,"status_code":200,"path":"/products","user_id":"U001"}'
  '{"timestamp":"2024-01-15T10:00:01Z","level":"ERROR","service":"database","message":"Error connecting to database: Connection timeout after 30s","duration_ms":30000,"status_code":500,"path":"/orders","user_id":"U002"}'
  '{"timestamp":"2024-01-15T10:00:02Z","level":"WARN","service":"auth","message":"Invalid token attempt from user U003, IP 192.168.1.100","duration_ms":12,"status_code":401,"path":"/login","user_id":"U003"}'
  '{"timestamp":"2024-01-15T10:01:00Z","level":"INFO","service":"api-gateway","message":"Request received POST /orders","duration_ms":230,"status_code":201,"path":"/orders","user_id":"U001"}'
  '{"timestamp":"2024-01-15T10:01:05Z","level":"ERROR","service":"payment","message":"Payment processing failed: Card declined for transaction TX-8821","duration_ms":2100,"status_code":402,"path":"/payment","user_id":"U004"}'
  '{"timestamp":"2024-01-15T10:02:00Z","level":"INFO","service":"api-gateway","message":"Request received GET /users/U001","duration_ms":38,"status_code":200,"path":"/users","user_id":"U001"}'
  '{"timestamp":"2024-01-15T10:02:10Z","level":"ERROR","service":"database","message":"Slow query detected: SELECT * FROM orders took 8500ms","duration_ms":8500,"status_code":200,"path":"/reports","user_id":"U005"}'
  '{"timestamp":"2024-01-15T10:03:00Z","level":"WARN","service":"cache","message":"Cache miss rate above 80% for key pattern /products/*","duration_ms":5,"status_code":200,"path":"/products","user_id":"U006"}'
  '{"timestamp":"2024-01-15T10:03:30Z","level":"ERROR","service":"api-gateway","message":"Rate limit exceeded for IP 10.0.0.50: 1000 requests per minute","duration_ms":1,"status_code":429,"path":"/products","user_id":"U007"}'
  '{"timestamp":"2024-01-15T10:04:00Z","level":"INFO","service":"payment","message":"Payment processed successfully TX-8822 amount 299.99 EUR","duration_ms":1200,"status_code":200,"path":"/payment","user_id":"U001"}'
)

for i in "${!DOCS[@]}"; do
  curl -s -u "$AUTH" -X POST "$OS_ENDPOINT/app-logs/_doc" \
    -H "Content-Type: application/json" \
    -d "${DOCS[$i]}" | jq '{result: .result, id: ._id}'
  sleep 0.2
done

echo ""
echo "Documentos indexados. Verificando count..."
curl -s -u "$AUTH" "$OS_ENDPOINT/app-logs/_count" | jq '{total: .count}'
```

---

## Paso 4: Queries full-text y agregaciones

```bash
OS_ENDPOINT=$(aws opensearch describe-domain \
  --domain-name lab07-opensearch --region eu-west-1 \
  --query 'DomainStatus.Endpoint' --output text | xargs -I{} echo "https://{}")
AUTH="admin:Lab07Admin#2024"

# Query 1: Buscar logs que contienen "database" (full-text search)
echo "=== Logs con 'database' ==="
curl -s -u "$AUTH" -X GET "$OS_ENDPOINT/app-logs/_search" \
  -H "Content-Type: application/json" \
  -d '{
    "query": {
      "match": {"message": "database"}
    }
  }' | jq '.hits.hits[] | {id: ._id, level: ._source.level, msg: ._source.message}'

# Query 2: Filtrar solo errores (keyword exact match)
echo ""
echo "=== Solo errores (ERROR level) ==="
curl -s -u "$AUTH" -X GET "$OS_ENDPOINT/app-logs/_search" \
  -H "Content-Type: application/json" \
  -d '{
    "query": {
      "term": {"level": "ERROR"}
    },
    "sort": [{"duration_ms": {"order": "desc"}}]
  }' | jq '.hits.hits[] | {service: ._source.service, msg: ._source.message, ms: ._source.duration_ms}'

# Query 3: Búsqueda combinada — errores de conexión
echo ""
echo "=== Errores de conexión o timeout ==="
curl -s -u "$AUTH" -X GET "$OS_ENDPOINT/app-logs/_search" \
  -H "Content-Type: application/json" \
  -d '{
    "query": {
      "bool": {
        "must": [
          {"term": {"level": "ERROR"}},
          {"match": {"message": "connection timeout"}}
        ]
      }
    }
  }' | jq '.hits.hits[] | {service: ._source.service, msg: ._source.message}'

# Query 4: Agregaciones — count de logs por nivel y servicio
echo ""
echo "=== Distribución de logs por nivel ==="
curl -s -u "$AUTH" -X GET "$OS_ENDPOINT/app-logs/_search" \
  -H "Content-Type: application/json" \
  -d '{
    "size": 0,
    "aggs": {
      "by_level": {
        "terms": {"field": "level"}
      },
      "avg_duration": {
        "avg": {"field": "duration_ms"}
      },
      "errors_by_service": {
        "filter": {"term": {"level": "ERROR"}},
        "aggs": {
          "services": {"terms": {"field": "service"}}
        }
      }
    }
  }' | jq '{
    levels: [.aggregations.by_level.buckets[] | {level: .key, count: .doc_count}],
    avg_duration_ms: .aggregations.avg_duration.value,
    errors_by_service: [.aggregations.errors_by_service.services.buckets[] | {service: .key, errors: .doc_count}]
  }'
```

---

## Paso 5: Abrir OpenSearch Dashboards

```bash
REGION="eu-west-1"
ENDPOINT=$(aws opensearch describe-domain \
  --domain-name lab07-opensearch --region "$REGION" \
  --query 'DomainStatus.Endpoint' --output text)

echo "Abre en el navegador:"
echo "  https://$ENDPOINT/_dashboards"
echo ""
echo "Usuario: admin"
echo "Password: Lab07Admin#2024"
```

**En OpenSearch Dashboards:**

1. **Crear index pattern:** Management → Index Patterns → `app-logs*` → campo de tiempo: `timestamp`

2. **Discover:** explorar documentos en tiempo real, filtrar por `level: ERROR`

3. **Crear visualización:**
   - Visualize → Bar Chart
   - Aggregation: Count | Bucket: X-Axis → Terms → `level.keyword`
   - Guarda como "Logs por nivel"

4. **Crear dashboard:**
   - Dashboard → New → Add → "Logs por nivel"

---

## Validación

```bash
./validate.sh
```

---

## ⚠️ Cleanup inmediato

```bash
REGION="eu-west-1"
aws opensearch delete-domain \
  --domain-name lab07-opensearch \
  --region "$REGION" && echo "Dominio en eliminación."
echo "La eliminación tarda 5-10 minutos pero no genera más coste."
```

---

## Conceptos demostrados

| Concepto | Demostrado en |
|---|---|
| Índice invertido vs B-Tree | Concepto: `text` vs `keyword` mapping |
| Mapping explícito de tipos | Paso 3: `keyword` para filtros exactos, `text` para full-text |
| `match` vs `term` — cuándo usar cada uno | Paso 4: `match` para full-text, `term` para exact match |
| `bool` query con `must` | Paso 4: query 3 combinando condiciones |
| Agregaciones (terms, avg, filter) | Paso 4: query 4 |
| OpenSearch Dashboards | Paso 5: index pattern, Discover, Visualize |
