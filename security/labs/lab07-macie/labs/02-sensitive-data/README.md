# Lab 07.02 — Findings de tipo SensitiveData

> **Coste:** GRATIS (free trial) | **Prerrequisito:** lab 07.01 completado

---

## Objetivo

Crear datos FICTICIOS que simulen PII, subirlos a S3, ejecutar un Discovery Job y verificar que Macie genera un finding de tipo `SensitiveData:S3Object/Personal`.

> **IMPORTANTE:** Todos los datos de este lab son completamente inventados. Nunca uses datos personales reales en labs de seguridad.

---

## Paso 1 — Crear archivo CSV con datos PII ficticios

```bash
export AWS_REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="lab07-macie-demo-${ACCOUNT_ID}"

# Crear CSV con datos PII completamente ficticios
cat > /tmp/clientes_ficticios.csv <<'CSV'
id,nombre,apellido,email,telefono,dni,fecha_nacimiento,tarjeta_credito
1,Juan,García,juan.garcia.ficticio@ejemplo-lab.invalid,+34 600 000 001,12345678A,1980-01-15,4111111111111111
2,María,López,maria.lopez.ficticia@ejemplo-lab.invalid,+34 600 000 002,87654321B,1990-06-20,5500005555555559
3,Carlos,Martínez,carlos.martinez.ficticio@ejemplo-lab.invalid,+34 600 000 003,11223344C,1975-11-30,378282246310005
4,Ana,Rodríguez,ana.rodriguez.ficticia@ejemplo-lab.invalid,+34 600 000 004,44332211D,1985-03-08,6011111111111117
5,Pedro,Sánchez,pedro.sanchez.ficticio@ejemplo-lab.invalid,+34 600 000 005,55667788E,1992-09-12,3530111333300000
CSV

echo "Archivo creado con datos completamente ficticios"
echo "Registros: $(wc -l < /tmp/clientes_ficticios.csv)"
```

```bash
# Subir al bucket de Macie
aws s3 cp /tmp/clientes_ficticios.csv \
  "s3://${BUCKET_NAME}/datos-sensibles/clientes_ficticios.csv"

echo "Archivo subido: s3://${BUCKET_NAME}/datos-sensibles/clientes_ficticios.csv"
```

---

## Paso 2 — Crear un Discovery Job

```bash
# Crear Discovery Job sobre el bucket
JOB_ID=$(aws macie2 create-classification-job \
  --job-type ONE_TIME \
  --name "lab07-pii-scan-$(date +%s)" \
  --description "Lab 07 - Escaneo de datos PII ficticios" \
  --s3-job-definition "{
    \"bucketDefinitions\": [{
      \"accountId\": \"${ACCOUNT_ID}\",
      \"buckets\": [\"${BUCKET_NAME}\"]
    }]
  }" \
  --region "$AWS_REGION" \
  --query 'jobId' --output text)

echo "Discovery Job creado: $JOB_ID"
```

```bash
# Monitorizar el estado del job
aws macie2 describe-classification-job \
  --job-id "$JOB_ID" \
  --region "$AWS_REGION" \
  --query '{Estado:jobStatus,Procesados:statistics.numberOfObjectsProcessed,Buckets:s3JobDefinition.bucketDefinitions[0].buckets}' \
  --output table
```

---

## Paso 3 — Esperar y verificar findings

```bash
# Esperar a que el job termine (normalmente 5-15 min para pocos objetos)
echo "Esperando que el Discovery Job complete..."
echo "Ejecuta el siguiente comando cada 2 minutos:"
echo ""
echo "aws macie2 describe-classification-job --job-id $JOB_ID --region $AWS_REGION --query '{Estado:jobStatus,Procesados:statistics.numberOfObjectsProcessed}' --output table"
```

```bash
# Una vez el job esté en estado COMPLETE, ver los findings
aws macie2 list-findings \
  --finding-criteria '{
    "criterion": {
      "type": {
        "eq": ["SensitiveData:S3Object/Personal", "SensitiveData:S3Object/Financial"]
      }
    }
  }' \
  --region "$AWS_REGION" \
  --query 'findingIds' \
  --output table
```

```bash
# Obtener detalle del finding (reemplaza FINDING_ID con el ID real)
FINDING_ID=$(aws macie2 list-findings \
  --finding-criteria '{
    "criterion": {
      "category": {"eq": ["SENSITIVE_INFORMATION"]}
    }
  }' \
  --region "$AWS_REGION" \
  --query 'findingIds[0]' --output text 2>/dev/null)

if [[ -n "$FINDING_ID" && "$FINDING_ID" != "None" ]]; then
  aws macie2 get-findings \
    --finding-ids "$FINDING_ID" \
    --region "$AWS_REGION" \
    --query 'findings[0].{
      Tipo:type,
      Severidad:severity.description,
      Bucket:resourcesAffected.s3Bucket.name,
      Objeto:resourcesAffected.s3Object.key,
      DatosSensibles:classificationDetails.result.sensitiveData
    }' \
    --output json
fi
```

---

## Paso 4 — Explorar el finding

Los findings de tipo `SensitiveData:` tienen esta estructura:

```json
{
  "type": "SensitiveData:S3Object/Personal",
  "severity": {"description": "HIGH"},
  "resourcesAffected": {
    "s3Bucket": {
      "name": "lab07-macie-demo-123456789012"
    },
    "s3Object": {
      "key": "datos-sensibles/clientes_ficticios.csv",
      "size": 450
    }
  },
  "classificationDetails": {
    "result": {
      "sensitiveData": [
        {
          "category": "PERSONAL_INFORMATION",
          "detections": [
            {"type": "EMAIL_ADDRESS", "count": 5},
            {"type": "PHONE_NUMBER", "count": 5},
            {"type": "CREDIT_CARD_NUMBER", "count": 5}
          ],
          "totalCount": 15
        }
      ],
      "status": {"code": "COMPLETE"}
    }
  }
}
```

**Para el examen — qué demuestra este finding:**
- **Tipo** `SensitiveData:` → el problema está en el **CONTENIDO** del objeto
- **Remediación** → proteger el contenido, no la configuración del bucket
- Si el bucket también estuviera público, habría **dos findings independientes**:
  - `SensitiveData:S3Object/Personal` (problema de contenido)
  - `Policy:IAMUser/S3BucketPubliclyAccessible` (problema de configuración)

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| Finding `SensitiveData:` → ¿qué remediar? | El **CONTENIDO** del objeto (cifrar, restringir, eliminar) |
| ¿Cómo se ejecuta un escaneo de un bucket específico? | `create-classification-job` con `--job-type ONE_TIME` |
| ¿Macie detecta tarjetas de crédito? | **Sí** — subtipo `SensitiveData:S3Object/Financial` |
| ¿Qué campo del finding indica el tipo de dato? | `classificationDetails.result.sensitiveData[].category` |
