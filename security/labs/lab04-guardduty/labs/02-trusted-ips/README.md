# Lab 04.02 — Trusted IP List y Threat IP List

> **Coste:** GRATIS (free trial) | **Prerrequisito:** lab 04.01 completado

---

## Objetivo

Crear una Trusted IP List para que GuardDuty no genere findings para IPs conocidas (ej: equipo de pentest), y una Threat IP List para añadir IOCs propios. Entender cuándo usar cada una vs Suppression Rules.

---

## Paso 1 — Obtener el Detector ID

```bash
export AWS_REGION="eu-west-1"

DETECTOR_ID=$(aws guardduty list-detectors \
  --region "$AWS_REGION" \
  --query 'DetectorIds[0]' --output text)

echo "Detector ID: $DETECTOR_ID"
```

---

## Paso 2 — Crear bucket S3 para las listas

Las IP lists deben estar en S3 con acceso desde GuardDuty.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
LISTS_BUCKET="lab04-guardduty-lists-${ACCOUNT_ID}"

aws s3api create-bucket \
  --bucket "$LISTS_BUCKET" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

echo "Bucket creado: $LISTS_BUCKET"
```

---

## Paso 3 — Crear y subir la Trusted IP List

```bash
# Crear archivo con IPs de confianza (IPs de ejemplo — en producción serían las de tu red)
# Formato: una IP o CIDR por línea
cat > /tmp/trusted-ips.txt << 'EOF'
10.0.0.0/8
192.168.1.100
203.0.113.50
EOF

# Subir a S3
aws s3 cp /tmp/trusted-ips.txt "s3://${LISTS_BUCKET}/trusted-ips.txt"

echo "Trusted IP List subida a S3"
```

### Activar la Trusted IP List en GuardDuty

```bash
# Crear la Trusted IP List en GuardDuty
IPSET_ID=$(aws guardduty create-ip-set \
  --detector-id "$DETECTOR_ID" \
  --name "lab04-trusted-ips" \
  --format TXT \
  --location "s3://${LISTS_BUCKET}/trusted-ips.txt" \
  --activate \
  --region "$AWS_REGION" \
  --query 'IpSetId' --output text)

echo "Trusted IP List creada y activada: $IPSET_ID"
```

### Verificar el estado

```bash
aws guardduty get-ip-set \
  --detector-id "$DETECTOR_ID" \
  --ip-set-id "$IPSET_ID" \
  --region "$AWS_REGION" \
  --query '{Nombre:Name,Estado:Status,Ubicacion:Location}' \
  --output table
```

Output esperado:
```
---------------------------------------------------------
|                      GetIpSet                          |
+---------+----------+----------------------------------+
|  Nombre | Estado   | Ubicacion                        |
+---------+----------+----------------------------------+
| lab04-  | ACTIVE   | s3://lab04-guardduty-lists-XXX/  |
| trusted |          | trusted-ips.txt                  |
+---------+----------+----------------------------------+
```

---

## Paso 4 — Crear una Threat IP List

```bash
# IPs que queremos que GuardDuty considere maliciosas (IOCs propios)
# En producción: feeds de threat intelligence internos o de tu ISAC
cat > /tmp/threat-ips.txt << 'EOF'
198.51.100.1
198.51.100.2
198.51.100.0/24
EOF

# Subir a S3
aws s3 cp /tmp/threat-ips.txt "s3://${LISTS_BUCKET}/threat-ips.txt"

# Crear Threat IP List en GuardDuty
THREATSET_ID=$(aws guardduty create-threat-intel-set \
  --detector-id "$DETECTOR_ID" \
  --name "lab04-threat-ips" \
  --format TXT \
  --location "s3://${LISTS_BUCKET}/threat-ips.txt" \
  --activate \
  --region "$AWS_REGION" \
  --query 'ThreatIntelSetId' --output text)

echo "Threat IP List creada y activada: $THREATSET_ID"
```

### Verificar la Threat IP List

```bash
aws guardduty get-threat-intel-set \
  --detector-id "$DETECTOR_ID" \
  --threat-intel-set-id "$THREATSET_ID" \
  --region "$AWS_REGION" \
  --query '{Nombre:Name,Estado:Status,Ubicacion:Location}' \
  --output table
```

---

## Paso 5 — Listar todas las listas activas

```bash
echo "=== Trusted IP Lists ==="
aws guardduty list-ip-sets \
  --detector-id "$DETECTOR_ID" \
  --region "$AWS_REGION" \
  --output table

echo "=== Threat IP Lists ==="
aws guardduty list-threat-intel-sets \
  --detector-id "$DETECTOR_ID" \
  --region "$AWS_REGION" \
  --output table
```

---

## Cuándo usar Trusted IP List vs Suppression Rules

Esta distinción es **crítica para el examen**:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    ¿Equipo de pentest genera findings?                   │
│                                                                          │
│  Opción A: Trusted IP List                                               │
│  ─────────────────────────                                               │
│  Añades las IPs del equipo de pentest a la Trusted IP List              │
│  → GuardDuty NUNCA generará findings desde esas IPs                    │
│  → Los findings no se crean en absoluto                                 │
│  → Correcto si las IPs son fijas y conocidas de antemano                │
│                                                                          │
│  Opción B: Suppression Rules                                             │
│  ─────────────────────────────                                           │
│  Creas una regla: finding_type=PenTest* AND user=pentest-user          │
│  → GuardDuty SÍ genera los findings                                    │
│  → Los findings se archivan automáticamente                             │
│  → Los findings NO se envían a Security Hub                             │
│  → Correcto si las IPs varían o el criterio es más complejo             │
└─────────────────────────────────────────────────────────────────────────┘
```

| Criterio | Trusted IP List | Suppression Rules |
|---------|-----------------|-------------------|
| **Basado en** | Dirección IP / CIDR | Cualquier atributo del finding |
| **Finding se crea** | No | Sí (pero archivado) |
| **Visible en consola** | No | Sí (como Archived) |
| **Enviado a Security Hub** | No aplica | No |
| **Cuándo usar** | IPs fijas y de total confianza | Ruido por comportamiento específico |

---

## Paso 6 — Limpiar (al terminar el lab)

```bash
# Desactivar y eliminar Trusted IP List
aws guardduty delete-ip-set \
  --detector-id "$DETECTOR_ID" \
  --ip-set-id "$IPSET_ID" \
  --region "$AWS_REGION"

# Desactivar y eliminar Threat IP List
aws guardduty delete-threat-intel-set \
  --detector-id "$DETECTOR_ID" \
  --threat-intel-set-id "$THREATSET_ID" \
  --region "$AWS_REGION"

# Eliminar bucket S3
aws s3 rb "s3://${LISTS_BUCKET}" --force

echo "Listas eliminadas"
```
