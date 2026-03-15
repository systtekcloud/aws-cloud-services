# =============================================================================
# s3.tf — Bucket S3 de test para generar tráfico
#
# Este bucket sirve como destino para medir si el tráfico pasa por NAT o no.
# Las EC2 subirán y descargarán objetos de este bucket.
# VPC Flow Logs capturará si esas operaciones pasaron por el NAT Gateway.
# =============================================================================

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "test" {
  # Nombre único usando account ID para evitar colisiones globales
  bucket = "${var.prefix}-lab-test-${data.aws_caller_identity.current.account_id}"

  # force_destroy permite borrar el bucket con objetos al hacer terraform destroy
  # En producción esto sería peligroso — aquí es necesario para cleanup limpio
  force_destroy = true

  tags = { Name = "${var.prefix}-test-bucket" }
}

# Bloquear acceso público — no necesitamos acceso desde internet
resource "aws_s3_bucket_public_access_block" "test" {
  bucket = aws_s3_bucket.test.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning deshabilitado — no necesitamos versiones en un bucket de test
resource "aws_s3_bucket_versioning" "test" {
  bucket = aws_s3_bucket.test.id
  versioning_configuration {
    status = "Disabled"
  }
}
