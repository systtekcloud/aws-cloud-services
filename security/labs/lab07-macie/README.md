# Lab 07 — Amazon Macie

> **Coste:** GRATIS durante 30 días de free trial | **Región:** eu-west-1

---

## Objetivo

Dominar Amazon Macie como clasificador de datos en S3: la distinción crítica entre findings `SensitiveData:` (contenido) y `Policy:` (configuración), Automated Discovery vs Discovery Jobs, y Custom Identifiers. Contenido frecuente en SAA-C03.

---

## La distinción más importante del lab

```
SensitiveData: finding    →    el CONTENIDO del objeto es el problema
                               Acción: proteger/cifrar/eliminar el objeto

Policy: finding           →    la CONFIGURACIÓN del bucket es el problema
                               Acción: corregir BPA, cifrado, bucket policy
```

El prefijo del finding te dice exactamente qué remediar.

---

## Labs

| Lab | Objetivo | Coste |
|-----|---------|-------|
| [01 — Setup](labs/01-setup/README.md) | Habilitar Macie + Automated Discovery | Free trial |
| [02 — Sensitive Data](labs/02-sensitive-data/README.md) | CSV con PII ficticio + Discovery Job + `SensitiveData:` finding | Free trial |
| [03 — Policy Findings](labs/03-policy-findings/README.md) | Bucket público → `Policy:` finding → remediar | Free trial |

**Orden recomendado:** 01 → 02 → 03

---

## Mapa conceptual

Ver [concept-map/README.md](concept-map/README.md) para:
- `SensitiveData:` vs `Policy:` — distinción crítica con subtipos
- Automated Discovery vs Discovery Jobs
- Cómo leer el prefijo para elegir la remediación correcta
- Macie vs Access Analyzer para detectar buckets públicos
- Analogía DLP (Data Loss Prevention)

---

## Terraform

El directorio [terraform/](terraform/) contiene:

```bash
cd terraform/

# Setup básico (Macie + bucket privado + Classification Job)
terraform init
terraform apply

# Con bucket público para demo de Policy: findings (INSEGURO A PROPÓSITO)
terraform apply -var="create_public_bucket=true"

# Limpiar
terraform destroy
```

---

## Scenarios SAA-C03

Ver [scenarios/README.md](scenarios/README.md) para 3 escenarios de examen:

1. Leer el prefijo del finding para elegir la remediación correcta
2. Macie vs Access Analyzer vs Config para detectar buckets públicos
3. Custom Identifiers para datos sensibles propietarios (regex)

---

## Limpieza

Ver [cleanup.md](cleanup.md) para instrucciones completas.

```bash
aws macie2 disable-macie --region eu-west-1
```

---

## Resumen SAA-C03

| Pregunta | Respuesta |
|---------|---------|
| `SensitiveData:` finding → ¿qué remediar? | El CONTENIDO del objeto (PII, credenciales) |
| `Policy:` finding → ¿qué remediar? | La CONFIGURACIÓN del bucket (BPA, cifrado, policy) |
| ¿Macie analiza RDS o EFS? | **No** — solo S3 |
| ¿Automated Discovery vs Discovery Job? | Discovery = exhaustivo/manual. Automated = continuo/sampling |
| ¿Cómo detectar formato propietario de datos? | **Custom Data Identifier** con regex |
| ¿Macie vs Access Analyzer? | Macie = contenido + configuración S3. Access Analyzer = permisos IAM efectivos |
