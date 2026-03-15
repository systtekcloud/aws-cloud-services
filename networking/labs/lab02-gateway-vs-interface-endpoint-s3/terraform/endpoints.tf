# =============================================================================
# endpoints.tf — S3 Gateway Endpoint
#
# GATEWAY ENDPOINT vs INTERFACE ENDPOINT para S3:
#
# Gateway Endpoint:
#   - Gratuito (sin coste por hora ni por GB procesado)
#   - Solo funciona dentro de la VPC (no accesible desde on-prem ni peering)
#   - Se implementa como entrada en la route table (prefix list → vpce)
#   - No tiene IP privada ni ENI — es una abstracción de enrutamiento
#   - Soporta S3 y DynamoDB únicamente
#
# Interface Endpoint (PrivateLink):
#   - $0.01/h + $0.01/GB procesado
#   - Accesible desde on-prem (via Direct Connect/VPN) y VPC Peering
#   - Tiene ENI con IP privada en la subnet
#   - Soporta la mayoría de servicios AWS
#
# Para este lab usamos Gateway Endpoint porque:
#   1. Es gratuito — demuestra el ahorro de coste real
#   2. Es el recomendado por AWS para S3 dentro de una VPC
#   3. El contraste con NAT Gateway es más impactante en coste
# =============================================================================

data "aws_region" "current" {}

resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${data.aws_region.current.name}.s3"

  # Gateway es el tipo correcto para S3 — no Interface
  # Interface Endpoint para S3 existe pero tiene coste adicional
  vpc_endpoint_type = "Gateway"

  # CLAVE: Solo asociamos este endpoint a la route table de subnet-gw-private.
  # subnet-nat-private NO está en esta lista → su tráfico S3 sigue por NAT GW.
  # AWS añade automáticamente una ruta en rt-gw-private:
  #   pl-6da54004 (prefix list S3 eu-west-1) → vpce-xxxxxxxxx
  route_table_ids = [aws_route_table.gw_private.id]

  # Política permisiva — permite todas las operaciones S3
  # En producción restricirías a buckets específicos o acciones concretas
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:*"
        Resource  = "*"
      }
    ]
  })

  tags = { Name = "${var.prefix}-s3-gateway-endpoint" }
}
