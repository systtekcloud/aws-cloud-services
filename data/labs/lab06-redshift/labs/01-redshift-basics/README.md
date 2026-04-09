# Lab 01 — Redshift Serverless: cargar datos y queries analíticas

> **Duración estimada:** 35 minutos | **Coste estimado:** ~$0.25 (Redshift Serverless 8 RPU × $0.36/RPU-hora × ~40 min)
> ⚠️ **Pausar el workgroup al terminar** — ver sección de limpieza.

---

## Objetivo

Crear un Redshift Serverless workgroup, cargar el dataset de ventas desde S3 via `COPY` command, ejecutar queries analíticas, y comparar el rendimiento con Athena sobre los mismos datos.

---

## Paso 1: Crear S3 bucket y subir datos

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
BUCKET="lab06-redshift-${ACCOUNT_ID}"

aws s3 mb "s3://$BUCKET" --region "$REGION"

# Dataset: ventas e-commerce extendido (más filas para ver el efecto de analytics)
cat > /tmp/orders.csv << 'EOF'
order_id,customer_id,product_id,category,quantity,unit_price,total,country,order_date,status
1001,C001,P101,Electronics,1,299.99,299.99,Spain,2024-01-02,completed
1002,C002,P205,Clothing,3,45.00,135.00,France,2024-01-03,completed
1003,C001,P305,Books,2,18.50,37.00,Spain,2024-01-03,completed
1004,C003,P101,Electronics,1,299.99,299.99,Germany,2024-01-04,completed
1005,C004,P410,Home,4,22.00,88.00,Italy,2024-01-05,completed
1006,C002,P505,Books,1,25.00,25.00,France,2024-01-05,returned
1007,C005,P601,Clothing,2,89.99,179.98,Spain,2024-01-06,completed
1008,C003,P205,Clothing,1,45.00,45.00,Germany,2024-01-07,completed
1009,C006,P101,Electronics,2,299.99,599.98,UK,2024-01-08,completed
1010,C001,P305,Books,3,18.50,55.50,Spain,2024-01-09,completed
2001,C007,P102,Electronics,1,499.99,499.99,Spain,2024-02-01,completed
2002,C008,P206,Clothing,2,65.00,130.00,France,2024-02-02,completed
2003,C007,P306,Books,1,32.00,32.00,Spain,2024-02-03,completed
2004,C009,P102,Electronics,1,499.99,499.99,Germany,2024-02-04,completed
2005,C010,P411,Home,3,35.00,105.00,Italy,2024-02-05,completed
2006,C001,P601,Clothing,1,89.99,89.99,Spain,2024-02-06,returned
2007,C002,P101,Electronics,1,299.99,299.99,France,2024-02-07,completed
2008,C011,P205,Clothing,4,45.00,180.00,UK,2024-02-08,completed
2009,C012,P410,Home,2,22.00,44.00,Germany,2024-02-09,completed
2010,C003,P505,Books,2,25.00,50.00,Germany,2024-02-10,completed
EOF

aws s3 cp /tmp/orders.csv "s3://$BUCKET/data/orders.csv"
echo "Datos subidos a s3://$BUCKET/data/orders.csv"
```

---

## Paso 2: Crear IAM role para Redshift (acceso S3)

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
BUCKET="lab06-redshift-${ACCOUNT_ID}"

cat > /tmp/redshift-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "redshift.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name lab06-redshift-role \
  --assume-role-policy-document file:///tmp/redshift-trust.json

cat > /tmp/redshift-s3-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::$BUCKET",
        "arn:aws:s3:::$BUCKET/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "glue:GetDatabase",
        "glue:GetTable",
        "glue:GetTables",
        "glue:GetPartitions"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name lab06-redshift-role \
  --policy-name lab06-redshift-s3 \
  --policy-document file:///tmp/redshift-s3-policy.json

ROLE_ARN=$(aws iam get-role \
  --role-name lab06-redshift-role \
  --query 'Role.Arn' --output text)

echo "Role ARN: $ROLE_ARN"
sleep 10
```

---

## Paso 3: Crear Redshift Serverless namespace y workgroup

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
ROLE_ARN=$(aws iam get-role --role-name lab06-redshift-role --query 'Role.Arn' --output text)

# Namespace (almacena databases, users, schemas)
aws redshift-serverless create-namespace \
  --namespace-name lab06-namespace \
  --admin-username adminuser \
  --admin-user-password "Lab06Admin#2024" \
  --iam-roles "$ROLE_ARN" \
  --region "$REGION"

echo "Namespace creado."

# Workgroup (cluster de compute — endpoints, VPC, RPU)
aws redshift-serverless create-workgroup \
  --workgroup-name lab06-workgroup \
  --namespace-name lab06-namespace \
  --base-capacity 8 \
  --publicly-accessible \
  --region "$REGION"

echo "Workgroup creado. Esperando estado AVAILABLE..."

while true; do
  STATE=$(aws redshift-serverless get-workgroup \
    --workgroup-name lab06-workgroup \
    --region "$REGION" \
    --query 'workgroup.status' \
    --output text)
  echo "  Estado: $STATE"
  [[ "$STATE" == "AVAILABLE" ]] && break
  sleep 20
done

# Obtener endpoint
ENDPOINT=$(aws redshift-serverless get-workgroup \
  --workgroup-name lab06-workgroup \
  --region "$REGION" \
  --query 'workgroup.endpoint.address' \
  --output text)

echo ""
echo "Endpoint: $ENDPOINT"
echo "Puerto:   5439"
echo "Usuario:  adminuser"
echo "Password: Lab06Admin#2024"
```

---

## Paso 4: Conectar y crear tabla

Usa el **Redshift Query Editor v2** en la consola AWS, o psql desde la CLI:

```bash
# Opción A: psql (requiere cliente PostgreSQL)
ENDPOINT=$(aws redshift-serverless get-workgroup \
  --workgroup-name lab06-workgroup \
  --region eu-west-1 \
  --query 'workgroup.endpoint.address' \
  --output text)

psql -h "$ENDPOINT" -p 5439 -U adminuser -d dev

# Opción B (recomendada para el lab): Redshift Query Editor v2
# Consola AWS → Redshift → Query Editor v2 → Connect → lab06-workgroup
```

**SQL para crear la tabla:**

```sql
-- Crear tabla de órdenes
CREATE TABLE IF NOT EXISTS orders (
    order_id    INTEGER     NOT NULL,
    customer_id VARCHAR(10) NOT NULL,
    product_id  VARCHAR(10) NOT NULL,
    category    VARCHAR(20) NOT NULL,
    quantity    INTEGER     NOT NULL,
    unit_price  DECIMAL(10,2) NOT NULL,
    total       DECIMAL(10,2) NOT NULL,
    country     VARCHAR(30) NOT NULL,
    order_date  DATE        NOT NULL,
    status      VARCHAR(20) NOT NULL
)
DISTSTYLE AUTO
SORTKEY (order_date);

-- Verificar tabla
SELECT * FROM information_schema.columns
WHERE table_name = 'orders'
ORDER BY ordinal_position;
```

---

## Paso 5: Cargar datos con COPY desde S3

```sql
-- COPY es la forma correcta de cargar datos en Redshift (bulk load, no INSERTs)
COPY orders
FROM 's3://lab06-redshift-<ACCOUNT_ID>/data/orders.csv'
IAM_ROLE 'arn:aws:iam::<ACCOUNT_ID>:role/lab06-redshift-role'
CSV
IGNOREHEADER 1
REGION 'eu-west-1'
DATEFORMAT 'YYYY-MM-DD';

-- Verificar carga
SELECT COUNT(*) FROM orders;
SELECT * FROM orders LIMIT 5;
```

> **Por qué COPY y no INSERT:** Redshift está optimizado para carga batch. `COPY` usa procesamiento paralelo en todos los nodos y es 100–1000x más rápido que INSERTs individuales. En producción nunca se usan INSERTs para cargar volúmenes grandes.

---

## Paso 6: Queries analíticas

```sql
-- Query 1: Revenue total por categoría
SELECT
    category,
    COUNT(*)                        AS num_orders,
    SUM(total)                      AS total_revenue,
    ROUND(AVG(total), 2)            AS avg_order_value,
    SUM(quantity)                   AS units_sold
FROM orders
WHERE status = 'completed'
GROUP BY category
ORDER BY total_revenue DESC;

-- Query 2: Revenue mensual por país
SELECT
    country,
    DATE_TRUNC('month', order_date) AS month,
    COUNT(*)                        AS orders,
    SUM(total)                      AS revenue
FROM orders
GROUP BY country, DATE_TRUNC('month', order_date)
ORDER BY month, revenue DESC;

-- Query 3: Top clientes por gasto total
SELECT
    customer_id,
    COUNT(DISTINCT order_id)   AS num_orders,
    SUM(total)                 AS total_spent,
    MAX(order_date)            AS last_order,
    LISTAGG(DISTINCT category, ', ')
        WITHIN GROUP (ORDER BY category) AS categories_purchased
FROM orders
GROUP BY customer_id
ORDER BY total_spent DESC
LIMIT 10;

-- Query 4: Tasa de retorno por categoría
SELECT
    category,
    COUNT(*) FILTER (WHERE status = 'returned') AS returned,
    COUNT(*) AS total,
    ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'returned') / COUNT(*), 1) AS return_rate_pct
FROM orders
GROUP BY category
ORDER BY return_rate_pct DESC;
```

---

## Paso 7: Comparar con Athena (mismos datos, distinto modelo)

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
BUCKET="lab06-redshift-${ACCOUNT_ID}"

# Crear workgroup Athena si no existe (del lab04)
aws athena create-work-group \
  --name lab06-athena-compare \
  --configuration "{\"ResultConfiguration\":{\"OutputLocation\":\"s3://$BUCKET/athena-results/\"}}" \
  --region "$REGION" 2>/dev/null || true

# La misma query en Athena (sobre el CSV en S3)
QUERY_ID=$(aws athena start-query-execution \
  --query-string "
    SELECT category,
           COUNT(*) AS num_orders,
           SUM(CAST(total AS DOUBLE)) AS total_revenue
    FROM (
      SELECT category, total, status
      FROM csv_data
    )
    WHERE status = 'completed'
    GROUP BY category
    ORDER BY total_revenue DESC
  " \
  --work-group lab06-athena-compare \
  --region "$REGION" \
  --query 'QueryExecutionId' \
  --output text 2>/dev/null || echo "")

echo ""
echo "=== Comparación Redshift vs Athena ==="
echo ""
echo "Redshift Serverless:"
echo "  - Datos cargados una vez con COPY → viven en el warehouse"
echo "  - Queries posteriores: columnar, MPP, sin leer S3"
echo "  - Rendimiento: muy rápido y predecible"
echo "  - Coste: \$0.36/RPU-hora siempre que el workgroup está activo"
echo ""
echo "Athena:"
echo "  - Datos siempre en S3, se leen en cada query"
echo "  - Sin carga previa, sin mantenimiento"
echo "  - Rendimiento: variable (depende del formato CSV/Parquet)"
echo "  - Coste: \$5/TB escaneado (CSV = más caro que Parquet)"
echo ""
echo "Cuándo Redshift gana:"
echo "  - Dashboards que ejecutan las mismas queries 50+ veces al día"
echo "  - JOINs complejos entre tablas grandes"
echo "  - Concurrencia alta de usuarios analíticos simultáneos"
```

---

## Validación

```bash
./validate.sh
```

---

## ⚠️ Pausar el workgroup al terminar

```bash
REGION="eu-west-1"

# Redshift Serverless se auto-pausa con inactividad, pero es mejor pausarlo explícitamente
# No hay un comando "pause" en Serverless — el auto-pause es automático tras ~30 min inactividad
# Para ahorrar completamente, elimina el workgroup (ver cleanup.md)

echo "Redshift Serverless hace auto-pause automáticamente tras 30 minutos de inactividad."
echo "Para eliminar completamente: ver cleanup.md"
```

---

## Conceptos demostrados

| Concepto | Demostrado en |
|---|---|
| COPY vs INSERT — bulk load | Paso 5: COPY desde S3 |
| Schema-on-write | Paso 4: CREATE TABLE antes de cargar |
| Almacenamiento columnar | Paso 6: queries de agregación eficientes |
| DISTSTYLE AUTO / SORTKEY | Paso 4: optimización automática |
| Redshift Serverless sin cluster | Paso 3: namespace + workgroup sin EC2 |
| Comparación con Athena | Paso 7: mismo dato, distinto modelo de coste |
