# modules/serving/main.tf
#
# Capa de serving:
#   Redshift Serverless → namespace + workgroup para BI sobre curated/
#   Redshift Spectrum   → acceso a processed/ vía Glue Data Catalog
#   (Athena workgroup ya creado en el módulo governance)

# ─── IAM Role para Redshift ───────────────────────────────────────────────────

resource "aws_iam_role" "redshift" {
  name = "${var.name_prefix}-redshift-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "redshift.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "redshift" {
  name = "redshift-s3-glue-spectrum"
  role = aws_iam_role.redshift.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Acceso S3 para COPY (curated/) y Spectrum (processed/)
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:ListBucket",
          "s3:GetBucketLocation", "s3:DeleteObject"
        ]
        Resource = [
          var.data_lake_bucket_arn,
          "${var.data_lake_bucket_arn}/*"
        ]
      },
      {
        # Glue Data Catalog para Redshift Spectrum
        Effect = "Allow"
        Action = [
          "glue:GetDatabase", "glue:GetDatabases",
          "glue:GetTable", "glue:GetTables",
          "glue:GetPartition", "glue:GetPartitions",
          "glue:BatchGetPartition"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["lakeformation:GetDataAccess"]
        Resource = "*"
      }
    ]
  })
}

# ─── Redshift Serverless Namespace ───────────────────────────────────────────
# Namespace = control plane (users, databases, encryption)
# Workgroup = data plane (compute, VPC, endpoints)

resource "aws_redshiftserverless_namespace" "data_lake" {
  namespace_name      = "${var.name_prefix}-ns"
  db_name             = "datalake"
  admin_username      = var.redshift_admin_user
  admin_user_password = var.redshift_admin_password

  # Asociar el IAM role para que Redshift pueda leer S3 y el Glue Catalog
  iam_roles = [aws_iam_role.redshift.arn]

  log_exports = ["userlog", "connectionlog", "useractivitylog"]

  tags = merge(var.common_tags, { Name = "${var.name_prefix}-namespace" })
}

# ─── Redshift Serverless Workgroup ───────────────────────────────────────────

resource "aws_redshiftserverless_workgroup" "data_lake" {
  namespace_name = aws_redshiftserverless_namespace.data_lake.namespace_name
  workgroup_name = "${var.name_prefix}-wg"

  # 8 RPU = mínimo para Serverless (64 GB RAM, escala automáticamente)
  base_capacity = var.redshift_base_capacity

  # Habilitar acceso público para simplificar el lab (en producción: false + VPC)
  publicly_accessible = false

  tags = merge(var.common_tags, { Name = "${var.name_prefix}-workgroup" })

  depends_on = [aws_redshiftserverless_namespace.data_lake]
}

# ─── SQL inicial: External Schema para Redshift Spectrum ─────────────────────
# Este bloque documenta el SQL que se ejecuta manualmente tras el despliegue.
# Redshift Spectrum permite hacer JOIN entre tablas Redshift (curated/)
# y tablas externas en S3 (processed/) usando el Glue Data Catalog.
#
# SQL a ejecutar en Redshift Query Editor v2:
#
#   CREATE EXTERNAL SCHEMA spectrum_processed
#   FROM DATA CATALOG
#   DATABASE '<glue_database_name>'
#   IAM_ROLE '<redshift_role_arn>'
#   REGION 'eu-west-1';
#
# Después:
#   SELECT * FROM spectrum_processed.raw LIMIT 10;
#   SELECT r.product_id, r.revenue, s.event_count
#   FROM curated_sales r
#   JOIN spectrum_processed.raw_events s ON r.product_id = s.product_id
#   WHERE r.month = 3;

# Exportar info necesaria para el SQL post-despliegue
resource "aws_ssm_parameter" "redshift_spectrum_sql" {
  name  = "/${var.name_prefix}/redshift/spectrum-setup-sql"
  type  = "String"
  value = <<-SQL
    -- Ejecutar en Redshift Query Editor v2 tras el despliegue
    CREATE EXTERNAL SCHEMA IF NOT EXISTS spectrum_processed
    FROM DATA CATALOG
    DATABASE '${var.glue_database_name}'
    IAM_ROLE '${aws_iam_role.redshift.arn}'
    REGION '${var.region}';

    -- Verificar tablas externas disponibles
    SELECT * FROM SVV_EXTERNAL_TABLES;

    -- Crear tabla interna para datos curated (cargados con COPY)
    CREATE TABLE IF NOT EXISTS public.curated_events (
      event_id   VARCHAR(36)     NOT NULL,
      event_time TIMESTAMP       NOT NULL,
      user_id    VARCHAR(64),
      event_type VARCHAR(32),
      payload    VARCHAR(MAX),
      year       SMALLINT,
      month      SMALLINT,
      day        SMALLINT
    )
    DISTSTYLE AUTO
    SORTKEY (event_time);
  SQL

  tags = var.common_tags
}
