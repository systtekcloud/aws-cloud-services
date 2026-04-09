# Lab 02 — Redshift Spectrum: queries sobre datos en S3

> **Duración estimada:** 25 minutos | **Coste estimado:** ~$0.15 + $5/TB escaneado via Spectrum
> ⚠️ **Prerequisito:** Lab 01 completado (workgroup AVAILABLE + tabla `orders` cargada)

---

## Objetivo

Configurar Redshift Spectrum para que el workgroup del Lab 01 consulte directamente los datos del Glue Catalog (tablas del Lab 04) sin cargarlos en Redshift. Demostrar un JOIN entre datos en el warehouse y datos en S3.

---

## Por qué Spectrum

```
Sin Spectrum:
  Hot data  → Redshift (cargado, rápido, caro por GB)
  Cold data → Athena (en S3, ad-hoc, barato)
  → Dos herramientas distintas, dos queries distintas, no puedes hacer JOINs entre ambas

Con Spectrum:
  Hot data  → Redshift warehouse (tablas normales)
  Cold data → S3 via Spectrum (tablas externas del Glue Catalog)
  → Un único SQL que hace JOIN entre ambas fuentes desde Redshift
```

**Caso de uso típico:** datos del último año en Redshift (fast, indexed), datos históricos (> 1 año) en S3 via Spectrum. Los analistas no saben la diferencia — mismo SQL, mismo cliente.

---

## Paso 1: Verificar que el Glue Catalog tiene datos del Lab 04

```bash
REGION="eu-west-1"

# Verificar que existe la base de datos y tabla del Lab 04
DB=$(aws glue get-database --name lab04_ecommerce --region "$REGION" \
  --query 'Database.Name' --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$DB" == "NOT_FOUND" ]]; then
  echo "⚠️  Base de datos lab04_ecommerce no encontrada."
  echo "   Ejecuta los Pasos 1-5 de lab04/labs/01-glue-catalog/README.md"
  echo "   (crea el bucket, sube el CSV, lanza el crawler)"
else
  echo "✓ Base de datos '$DB' encontrada."
  aws glue get-tables --database-name lab04_ecommerce --region "$REGION" \
    --query 'TableList[].{Name:Name,Location:StorageDescriptor.Location}'
fi
```

---

## Paso 2: Añadir permisos Glue al rol de Redshift

```bash
REGION="eu-west-1"

# El rol ya tiene permisos básicos de Glue del Lab 01
# Añadir acceso al bucket del Lab 04 (raw data)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

cat > /tmp/spectrum-s3-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::lab04-glue-raw-$ACCOUNT_ID",
        "arn:aws:s3:::lab04-glue-raw-$ACCOUNT_ID/*",
        "arn:aws:s3:::lab04-glue-processed-$ACCOUNT_ID",
        "arn:aws:s3:::lab04-glue-processed-$ACCOUNT_ID/*"
      ]
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name lab06-redshift-role \
  --policy-name lab06-spectrum-s3 \
  --policy-document file:///tmp/spectrum-s3-policy.json

echo "Permisos Spectrum añadidos."
```

---

## Paso 3: Crear external schema en Redshift

Conéctate al **Redshift Query Editor v2** y ejecuta:

```sql
-- Crear external schema que apunta al Glue Catalog
CREATE EXTERNAL SCHEMA IF NOT EXISTS spectrum_lab04
FROM DATA CATALOG
DATABASE 'lab04_ecommerce'
IAM_ROLE 'arn:aws:iam::<ACCOUNT_ID>:role/lab06-redshift-role'
REGION 'eu-west-1';

-- Verificar tablas disponibles via Spectrum
SELECT schemaname, tablename, location
FROM svv_external_tables
WHERE schemaname = 'spectrum_lab04';
```

> **Nota:** Sustituye `<ACCOUNT_ID>` por tu Account ID real. Puedes obtenerlo con:
> `aws sts get-caller-identity --query Account --output text`

---

## Paso 4: Queries sobre datos S3 desde Redshift

```sql
-- Query 1: Revenue por categoría en datos S3 (via Spectrum)
-- Los datos son del Lab 04 — mismo CSV que usamos en Athena
SELECT
    category,
    COUNT(*)                  AS orders_s3,
    SUM(CAST(total AS FLOAT)) AS revenue_s3
FROM spectrum_lab04.sales
GROUP BY category
ORDER BY revenue_s3 DESC;

-- Query 2: JOIN entre datos Redshift (hot) y datos S3 (cold)
-- orders = tabla Redshift del Lab 01 (2024 data)
-- spectrum_lab04.sales = datos del Lab 04 en S3 (también 2024, distinto dataset)
SELECT
    r.category,
    r.orders_redshift,
    r.revenue_redshift,
    COALESCE(s.orders_s3, 0)  AS orders_s3,
    COALESCE(s.revenue_s3, 0) AS revenue_s3
FROM (
    SELECT category,
           COUNT(*)  AS orders_redshift,
           SUM(total) AS revenue_redshift
    FROM orders
    GROUP BY category
) r
LEFT JOIN (
    SELECT category,
           COUNT(*)                  AS orders_s3,
           SUM(CAST(total AS FLOAT)) AS revenue_s3
    FROM spectrum_lab04.sales
    GROUP BY category
) s ON r.category = s.category
ORDER BY r.revenue_redshift DESC;

-- Query 3: Datos históricos via Spectrum con filtro de partición
-- Spectrum usa las particiones del Glue Catalog para pushdown (lee menos datos)
SELECT year, month, COUNT(*) AS orders
FROM spectrum_lab04.sales
GROUP BY year, month
ORDER BY year, month;
```

---

## Paso 5: Verificar partition pruning (optimización de Spectrum)

```sql
-- Esta query filtra por partición — Spectrum solo lee las particiones relevantes
-- Mucho más barato que leer todos los datos S3
EXPLAIN
SELECT COUNT(*), SUM(CAST(total AS FLOAT)) AS revenue
FROM spectrum_lab04.sales
WHERE year = '2024' AND month = '01';

-- Observa en el EXPLAIN plan:
-- "S3 Seq Scan spectrum_lab04.sales"
-- "Filter: ((year = '2024') AND (month = '01'))"
-- → Solo lee la partición year=2024/month=01, no todo el bucket
```

---

## Cuándo Spectrum vs mover datos a Redshift

```
Datos que consultas frecuentemente (hot):
  → Carga en Redshift con COPY
  → Máximo rendimiento, sin latencia S3

Datos históricos > 6 meses (cold):
  → Déjalos en S3, accede via Spectrum
  → No pagas almacenamiento Redshift por datos raramente consultados
  → Solo pagas $5/TB escaneado en Spectrum cuando los consultas

Datos que mezclas con datos hot en JOINs:
  → Spectrum permite el JOIN desde un único SQL
  → Sin necesidad de mover datos ni usar dos herramientas distintas

Volumen muy grande (PBs) que no cabe en Redshift:
  → Redshift Spectrum puede escanear PBs en S3
  → Solo pagas por el compute (RPU-hora) + datos escaneados

Regla simple:
  ¿Se consulta > 1 vez/semana en JOINs complejos? → Cargar en Redshift
  ¿Se consulta < 1 vez/mes o datos históricos?    → Dejar en S3 + Spectrum
```

---

## Limpieza del external schema

```sql
-- Eliminar solo el external schema (no afecta al Glue Catalog)
DROP SCHEMA IF EXISTS spectrum_lab04;
```

---

## Conceptos demostrados

| Concepto | Demostrado en |
|---|---|
| External schema apuntando a Glue Catalog | Paso 3: `FROM DATA CATALOG DATABASE` |
| Spectrum escanea S3 sin mover datos | Paso 4: query sobre `spectrum_lab04.sales` |
| JOIN entre Redshift + S3 en un SQL | Paso 4: query 2 con JOIN |
| Partition pruning en Spectrum | Paso 5: EXPLAIN con filtro por año/mes |
| Cuándo mover vs dejar en S3 | Paso 5: tabla de decisión |
