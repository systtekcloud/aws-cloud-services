# Lab 01 — Glue Catalog + Crawler + Athena

> **Duración estimada:** 30 minutos | **Coste estimado:** ~$0.50 (Crawler por minuto + Athena por TB escaneado)

---

## Objetivo

Subir un dataset CSV ficticio a S3, lanzar un Glue Crawler que descubra el schema automáticamente, verificar la tabla creada en el Catalog, y consultarla con Athena sin mover los datos.

---

## Paso 1: Crear S3 buckets y subir datos

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
RAW_BUCKET="lab04-glue-raw-${ACCOUNT_ID}"
RESULTS_BUCKET="lab04-glue-results-${ACCOUNT_ID}"

aws s3 mb "s3://$RAW_BUCKET" --region "$REGION"
aws s3 mb "s3://$RESULTS_BUCKET" --region "$REGION"

# Dataset ficticio: ventas de e-commerce
cat > /tmp/sales_2024_01.csv << 'EOF'
order_id,customer_id,product_id,category,quantity,unit_price,total,country,order_date
1001,C001,P101,Electronics,1,299.99,299.99,Spain,2024-01-02
1002,C002,P205,Clothing,3,45.00,135.00,France,2024-01-03
1003,C001,P305,Books,2,18.50,37.00,Spain,2024-01-03
1004,C003,P101,Electronics,1,299.99,299.99,Germany,2024-01-04
1005,C004,P410,Home,4,22.00,88.00,Italy,2024-01-05
1006,C002,P505,Books,1,25.00,25.00,France,2024-01-05
1007,C005,P601,Clothing,2,89.99,179.98,Spain,2024-01-06
1008,C003,P205,Clothing,1,45.00,45.00,Germany,2024-01-07
1009,C006,P101,Electronics,2,299.99,599.98,UK,2024-01-08
1010,C001,P305,Books,3,18.50,55.50,Spain,2024-01-09
EOF

cat > /tmp/sales_2024_02.csv << 'EOF'
order_id,customer_id,product_id,category,quantity,unit_price,total,country,order_date
2001,C007,P102,Electronics,1,499.99,499.99,Spain,2024-02-01
2002,C008,P206,Clothing,2,65.00,130.00,France,2024-02-02
2003,C007,P306,Books,1,32.00,32.00,Spain,2024-02-03
2004,C009,P102,Electronics,1,499.99,499.99,Germany,2024-02-04
2005,C010,P411,Home,3,35.00,105.00,Italy,2024-02-05
EOF

# Subir con estructura de partición por mes
aws s3 cp /tmp/sales_2024_01.csv "s3://$RAW_BUCKET/sales/year=2024/month=01/sales.csv"
aws s3 cp /tmp/sales_2024_02.csv "s3://$RAW_BUCKET/sales/year=2024/month=02/sales.csv"

echo "Datos subidos a s3://$RAW_BUCKET/sales/"
aws s3 ls "s3://$RAW_BUCKET/sales/" --recursive
```

---

## Paso 2: Crear base de datos en Glue Catalog

```bash
REGION="eu-west-1"

aws glue create-database \
  --database-input '{
    "Name": "lab04_ecommerce",
    "Description": "Lab04 e-commerce data lake database"
  }' \
  --region "$REGION"

echo "Base de datos 'lab04_ecommerce' creada en Glue Catalog."

# Verificar
aws glue get-database \
  --name lab04_ecommerce \
  --region "$REGION" \
  --query 'Database.{Name:Name,Description:Description}'
```

---

## Paso 3: Crear rol IAM para el Crawler

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
RAW_BUCKET="lab04-glue-raw-${ACCOUNT_ID}"

cat > /tmp/glue-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "glue.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name lab04-glue-crawler-role \
  --assume-role-policy-document file:///tmp/glue-trust.json

# Política gestionada de Glue
aws iam attach-role-policy \
  --role-name lab04-glue-crawler-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole

# Acceso S3 al bucket raw
cat > /tmp/glue-s3-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::$RAW_BUCKET",
      "arn:aws:s3:::$RAW_BUCKET/*"
    ]
  }]
}
EOF

aws iam put-role-policy \
  --role-name lab04-glue-crawler-role \
  --policy-name lab04-glue-s3-access \
  --policy-document file:///tmp/glue-s3-policy.json

ROLE_ARN=$(aws iam get-role \
  --role-name lab04-glue-crawler-role \
  --query 'Role.Arn' --output text)
echo "Role ARN: $ROLE_ARN"
sleep 10
```

---

## Paso 4: Crear y ejecutar el Crawler

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
RAW_BUCKET="lab04-glue-raw-${ACCOUNT_ID}"
ROLE_ARN=$(aws iam get-role \
  --role-name lab04-glue-crawler-role \
  --query 'Role.Arn' --output text)

aws glue create-crawler \
  --name lab04-sales-crawler \
  --role "$ROLE_ARN" \
  --database-name lab04_ecommerce \
  --targets "{
    \"S3Targets\": [{
      \"Path\": \"s3://$RAW_BUCKET/sales/\"
    }]
  }" \
  --schema-change-policy '{
    "UpdateBehavior": "UPDATE_IN_DATABASE",
    "DeleteBehavior": "LOG"
  }' \
  --region "$REGION"

echo "Iniciando crawler..."
aws glue start-crawler \
  --name lab04-sales-crawler \
  --region "$REGION"

# Esperar a que termine
while true; do
  STATE=$(aws glue get-crawler \
    --name lab04-sales-crawler \
    --region "$REGION" \
    --query 'Crawler.State' \
    --output text)
  echo "$(date -u +%H:%M:%S) Estado: $STATE"
  [[ "$STATE" == "READY" ]] && break
  sleep 15
done

echo "Crawler finalizado."
```

---

## Paso 5: Verificar tabla en Glue Catalog

```bash
REGION="eu-west-1"

# Ver tablas creadas
aws glue get-tables \
  --database-name lab04_ecommerce \
  --region "$REGION" \
  --query 'TableList[].{Name:Name,Columns:StorageDescriptor.Columns[].{Col:Name,Type:Type}}'

# Ver la tabla en detalle
aws glue get-table \
  --database-name lab04_ecommerce \
  --name sales \
  --region "$REGION" \
  --query 'Table.{
    Name:Name,
    Location:StorageDescriptor.Location,
    Format:StorageDescriptor.InputFormat,
    Columns:StorageDescriptor.Columns,
    Partitions:PartitionKeys
  }'
```

Observa:
- El Crawler detectó automáticamente los tipos (`order_id: int`, `total: double`, `order_date: string`)
- Detectó las particiones `year` y `month` de la estructura de carpetas
- El formato es CSV con separador `,`

---

## Paso 6: Consultar con Athena (sin mover datos)

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="eu-west-1"
RESULTS_BUCKET="lab04-glue-results-${ACCOUNT_ID}"

# Configurar workgroup de Athena con output en S3
aws athena create-work-group \
  --name lab04-workgroup \
  --configuration "{
    \"ResultConfiguration\": {
      \"OutputLocation\": \"s3://$RESULTS_BUCKET/athena-results/\"
    }
  }" \
  --region "$REGION" 2>/dev/null || true

# Query 1: Total de ventas por categoría
QUERY_ID=$(aws athena start-query-execution \
  --query-string "
    SELECT
      category,
      COUNT(*) as num_orders,
      SUM(total) as total_revenue,
      AVG(total) as avg_order_value
    FROM lab04_ecommerce.sales
    GROUP BY category
    ORDER BY total_revenue DESC;
  " \
  --work-group lab04-workgroup \
  --region "$REGION" \
  --query 'QueryExecutionId' \
  --output text)

echo "Query en ejecución: $QUERY_ID"
sleep 5

# Obtener resultados
aws athena get-query-results \
  --query-execution-id "$QUERY_ID" \
  --region "$REGION" \
  --query 'ResultSet.Rows[*].Data[*].VarCharValue' \
  --output table
```

```bash
# Query 2: Ventas por país y mes (usando particiones)
QUERY_ID2=$(aws athena start-query-execution \
  --query-string "
    SELECT
      country,
      year,
      month,
      COUNT(*) as orders,
      SUM(total) as revenue
    FROM lab04_ecommerce.sales
    WHERE year = '2024'
    GROUP BY country, year, month
    ORDER BY revenue DESC;
  " \
  --work-group lab04-workgroup \
  --region "$REGION" \
  --query 'QueryExecutionId' \
  --output text)

sleep 5

aws athena get-query-results \
  --query-execution-id "$QUERY_ID2" \
  --region "$REGION" \
  --query 'ResultSet.Rows[*].Data[*].VarCharValue' \
  --output table

# Ver cuántos bytes escaneó (coste)
aws athena get-query-execution \
  --query-execution-id "$QUERY_ID2" \
  --region "$REGION" \
  --query 'QueryExecution.Statistics.DataScannedInBytes'
```

---

## Validación

```bash
./validate.sh
```

---

## Limpieza (solo este lab)

```bash
REGION="eu-west-1"
aws glue delete-crawler --name lab04-sales-crawler --region "$REGION" 2>/dev/null || true
aws glue delete-database --name lab04_ecommerce --region "$REGION" 2>/dev/null || true
# S3 e IAM se eliminan en cleanup.md global
```

---

## Conceptos demostrados

| Concepto | Demostrado en |
|---|---|
| Glue Crawler infiere schema | Paso 4: detecta tipos y particiones automáticamente |
| Particiones detectadas del path S3 | `year=2024/month=01/` → partition keys |
| Glue Catalog como metastore | Paso 5: `get-table` muestra schema centralizado |
| Athena lee desde Catalog sin mover datos | Paso 6: SQL sobre S3 directo |
| Coste Athena por bytes escaneados | Paso 6: `DataScannedInBytes` |
