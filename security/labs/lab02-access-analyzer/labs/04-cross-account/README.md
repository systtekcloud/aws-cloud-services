# Lab 02.04 — IAM Role con trust policy cross-account

> **Coste:** GRATIS | **Prerrequisito:** lab 02.01 completado (analyzer activo)

---

## Objetivo

Crear un IAM Role con una trust policy que permite `AssumeRole` desde otra cuenta AWS. Verificar que Access Analyzer genera un finding, y entender cuándo archivar (acceso intencionado) vs cuándo remediar (error de configuración).

---

## Paso 1 — Crear IAM Role con trust policy cross-account

```bash
export AWS_REGION="eu-west-1"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ANALYZER_NAME="lab02-account-analyzer"
export ANALYZER_ARN="arn:aws:access-analyzer:${AWS_REGION}:${ACCOUNT_ID}:analyzer/${ANALYZER_NAME}"
export EXTERNAL_ACCOUNT="111122223333"  # cuenta externa ficticia
export ROLE_NAME="lab02-cross-account-role"

# Crear trust policy que permite AssumeRole desde cuenta externa
cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${EXTERNAL_ACCOUNT}:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": {}
    }
  ]
}
EOF

# Crear el rol
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file:///tmp/trust-policy.json \
  --description "Lab02: rol de prueba con acceso cross-account para Access Analyzer"

echo "Rol creado: $ROLE_NAME"
```

Output esperado:
```json
{
    "Role": {
        "RoleName": "lab02-cross-account-role",
        "Arn": "arn:aws:iam::123456789012:role/lab02-cross-account-role",
        ...
    }
}
```

---

## Paso 2 — Esperar el finding de Access Analyzer

Access Analyzer detecta cambios en IAM roles automáticamente. Los roles IAM **no admiten** `start-resource-scan` manual, por lo que hay que esperar a que el ciclo automático se ejecute (puede tardar hasta 30 minutos).

```bash
echo "Esperando 2 minutos para que Access Analyzer detecte el rol..."
sleep 120

# Buscar finding del rol
aws accessanalyzer list-findings \
  --analyzer-arn "$ANALYZER_ARN" \
  --filter "{\"resourceType\": {\"eq\": [\"AWS::IAM::Role\"]}, \"status\": {\"eq\": [\"ACTIVE\"]}}" \
  --region "$AWS_REGION" \
  --query 'findings[].{ID:id,Recurso:resource,Principal:principal,Estado:status}' \
  --output table
```

Si el finding no aparece tras 2 minutos, esperar hasta 30 minutos — Access Analyzer tiene un ciclo de análisis periódico para recursos IAM.

---

## Paso 3 — Ver el detalle del finding

```bash
FINDING_ID=$(aws accessanalyzer list-findings \
  --analyzer-arn "$ANALYZER_ARN" \
  --filter "{\"resourceType\": {\"eq\": [\"AWS::IAM::Role\"]}, \"status\": {\"eq\": [\"ACTIVE\"]}}" \
  --region "$AWS_REGION" \
  --query 'findings[0].id' \
  --output text)

aws accessanalyzer get-finding \
  --analyzer-arn "$ANALYZER_ARN" \
  --id "$FINDING_ID" \
  --region "$AWS_REGION"
```

Output esperado:
```json
{
    "finding": {
        "principal": {
            "AWS": "arn:aws:iam::111122223333:root"
        },
        "action": ["sts:AssumeRole"],
        "resource": "arn:aws:iam::123456789012:role/lab02-cross-account-role",
        "resourceType": "AWS::IAM::Role",
        "status": "ACTIVE",
        "isPublic": false
    }
}
```

---

## Paso 4 — Decidir: Archive vs Remediar

### Caso A: el acceso es intencionado (rol de auditoría cross-account)

```bash
# Archivar con nota de por qué es legítimo
aws accessanalyzer update-findings \
  --analyzer-arn "$ANALYZER_ARN" \
  --ids "$FINDING_ID" \
  --status ARCHIVED \
  --region "$AWS_REGION"

echo "Finding archivado — acceso cross-account documentado como intencionado"
```

### Caso B: el acceso fue un error (remediar)

```bash
# Opción 1: Eliminar el rol completamente
aws iam delete-role --role-name "$ROLE_NAME"

# Opción 2: Cambiar la trust policy para que solo permita tu propia cuenta
cat > /tmp/trust-policy-fixed.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${ACCOUNT_ID}:root"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam update-assume-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-document file:///tmp/trust-policy-fixed.json

echo "Trust policy corregida — solo permite AssumeRole desde la cuenta propia"
```

---

## Paso 5 — Limpiar

```bash
# Si usaste la Opción 2 en el paso anterior, eliminar el rol ahora
aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || echo "Rol ya eliminado"
```

---

## Cuándo archivar vs cuándo remediar

```
IAM Role con trust policy que permite AssumeRole desde cuenta-auditoria-987654321

¿Es intencionado?
│
├── Sí → ¿Está documentado y autorizado?
│         Sí → Archive + nota en el finding
│         No → Documentar primero, luego Archive
│
└── No → Corregir la trust policy → finding se Resuelve automáticamente
```

**Ejemplos de acceso cross-account INTENCIONADO (Archive):**
- Rol de lectura para herramienta de auditoría de terceros (Datadog, Splunk)
- Rol de despliegue para pipeline CI/CD en otra cuenta
- Rol de acceso para cuenta centralizada de seguridad (Security Account en Organizations)

**Ejemplos de acceso cross-account NO intencionado (Remediar):**
- Rol copiado de otro entorno con la trust policy incorrecta
- Cuenta externa ya no es partner/proveedor activo
- Trust policy con `"AWS": "*"` (permite cualquier cuenta)

---

## Diferencia con analyzer de tipo ORGANIZATION

Si usas un analyzer de tipo `ORGANIZATION`, los roles que permiten `AssumeRole` desde otra cuenta de tu organización **no generan finding** (están dentro de la zona de confianza). Solo generan finding los accesos desde fuera de la organización.

En este lab usamos `ACCOUNT`, por lo que cualquier acceso cross-account genera finding independientemente de si es otra cuenta de tu organización o no.
