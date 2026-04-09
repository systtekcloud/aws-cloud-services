# modules/governance/main.tf
#
# Glue Data Catalog + Lake Formation
#   - Base de datos del catálogo (metastore centralizado)
#   - Registro del bucket S3 en Lake Formation
#   - IAM role para Glue Crawlers y ETL Jobs
#   - Permisos Lake Formation sobre la base de datos

# ─── Glue Data Catalog Database ──────────────────────────────────────────────

resource "aws_glue_catalog_database" "data_lake" {
  name        = "${replace(var.name_prefix, "-", "_")}_catalog"
  description = "Base de datos del data lake ${var.name_prefix} — schemas para raw y processed"

  # Location URI — apunta al processed/ del data lake
  location_uri = "s3://${var.data_lake_bucket_id}/processed/"
}

# ─── Lake Formation — registrar el bucket ────────────────────────────────────
# Lake Formation necesita ser el "propietario" del bucket para
# poder aplicar permisos tabla/columna/fila sobre Athena, EMR y Glue.

resource "aws_lakeformation_resource" "data_lake" {
  arn = var.data_lake_bucket_arn
}

# ─── IAM Role para Glue (Crawlers + ETL Jobs) ────────────────────────────────

resource "aws_iam_role" "glue" {
  name = "${var.name_prefix}-glue-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3" {
  name = "s3-data-lake-access"
  role = aws_iam_role.glue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
          "s3:ListBucket", "s3:GetBucketLocation"
        ]
        Resource = [
          var.data_lake_bucket_arn,
          "${var.data_lake_bucket_arn}/*"
        ]
      },
      {
        # Glue necesita acceso a Glue Catalog y Lake Formation
        Effect   = "Allow"
        Action   = ["lakeformation:GetDataAccess", "lakeformation:GrantPermissions"]
        Resource = "*"
      }
    ]
  })
}

# ─── Lake Formation — permisos para el role de Glue ─────────────────────────

resource "aws_lakeformation_permissions" "glue_database" {
  principal   = aws_iam_role.glue.arn
  permissions = ["CREATE_TABLE", "DESCRIBE", "ALTER", "DROP"]

  database {
    name = aws_glue_catalog_database.data_lake.name
  }
}

resource "aws_lakeformation_permissions" "glue_data_location" {
  principal   = aws_iam_role.glue.arn
  permissions = ["DATA_LOCATION_ACCESS"]

  data_location {
    arn = var.data_lake_bucket_arn
  }
}

# ─── IAM Role para Athena ─────────────────────────────────────────────────────

resource "aws_iam_role" "athena" {
  name = "${var.name_prefix}-athena-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "athena.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "athena_s3" {
  name = "athena-s3-access"
  role = aws_iam_role.athena.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [
          var.data_lake_bucket_arn,
          "${var.data_lake_bucket_arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["lakeformation:GetDataAccess"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "glue:GetTable", "glue:GetTables", "glue:GetDatabase",
          "glue:GetDatabases", "glue:GetPartitions", "glue:GetPartition"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults"]
        Resource = "*"
      }
    ]
  })
}

# ─── Athena Workgroup ─────────────────────────────────────────────────────────

resource "aws_athena_workgroup" "data_lake" {
  name        = "${var.name_prefix}-workgroup"
  description = "Workgroup Athena para queries sobre el data lake"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${var.data_lake_bucket_id}/athena-results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  tags = var.common_tags
}
