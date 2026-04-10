variable "environment"         { type = string }
variable "productos_stream_arn" { type = string }
variable "stock_stream_arn"     { type = string }
variable "opensearch_endpoint"  { type = string }
variable "redis_endpoint"       { type = string }
variable "redis_port"           { type = string default = "6379" }

# ── IAM para Lambda projector ─────────────────────────────────────────────────

resource "aws_iam_role" "projector" {
  name = "cqrs-projector-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "projector" {
  role = aws_iam_role.projector.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetRecords", "dynamodb:GetShardIterator", "dynamodb:DescribeStream", "dynamodb:ListStreams"]
        Resource = [var.productos_stream_arn, var.stock_stream_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["es:ESHttpPost", "es:ESHttpPut", "es:ESHttpDelete"]
        Resource = "arn:aws:es:*:*:domain/*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# ── Lambda: projector (DynamoDB Streams → OpenSearch + Redis) ─────────────────

data "archive_file" "projector" {
  type        = "zip"
  output_path = "/tmp/cqrs-projector.zip"
  source {
    content  = <<-PYTHON
      import json, boto3, os
      from urllib.request import Request, urlopen

      def deserialize_dynamodb(item):
          """Convierte formato DynamoDB {'S': '...', 'N': '...'} a dict normal"""
          result = {}
          for k, v in item.items():
              if 'S' in v: result[k] = v['S']
              elif 'N' in v: result[k] = float(v['N'])
              elif 'BOOL' in v: result[k] = v['BOOL']
          return result

      def index_opensearch(doc_id, doc, index='productos'):
          endpoint = os.environ['OPENSEARCH_ENDPOINT']
          url = f"https://{endpoint}/{index}/_doc/{doc_id}"
          req = Request(url, data=json.dumps(doc).encode(), method='PUT')
          req.add_header('Content-Type', 'application/json')
          urlopen(req)

      def delete_opensearch(doc_id, index='productos'):
          endpoint = os.environ['OPENSEARCH_ENDPOINT']
          url = f"https://{endpoint}/{index}/_doc/{doc_id}"
          req = Request(url, method='DELETE')
          try: urlopen(req)
          except: pass  # puede no existir

      def invalidate_redis(keys):
          """En prod: usar redis-py con VPC endpoint"""
          # Aquí simulamos — en prod conectar via ElastiCache cluster endpoint
          print(f"Invalidando cache keys: {keys}")

      def handler(event, context):
          for record in event['Records']:
              event_name = record['eventName']
              table_arn  = record['eventSourceARN']
              is_stock   = 'stock' in table_arn

              if event_name == 'REMOVE':
                  keys = record['dynamodb']['Keys']
                  producto_id = keys['producto_id']['S']
                  if not is_stock:
                      delete_opensearch(producto_id)
                  invalidate_redis([f'producto:{producto_id}', f'stock:{producto_id}'])
                  continue

              new_image = record['dynamodb'].get('NewImage', {})
              if not new_image:
                  continue

              doc = deserialize_dynamodb(new_image)
              producto_id = doc.get('producto_id')

              if is_stock:
                  # Solo invalidamos cache de stock — OpenSearch no indexa stock
                  invalidate_redis([f'stock:{producto_id}', f'categoria:{doc.get("categoria", "")}:listado'])
              else:
                  # Indexar en OpenSearch
                  index_opensearch(producto_id, doc)
                  # Invalidar cache de producto y listados de su categoría
                  invalidate_redis([
                      f'producto:{producto_id}',
                      f'categoria:{doc.get("categoria", "")}:listado',
                  ])
    PYTHON
    filename = "handler.py"
  }
}

resource "aws_lambda_function" "projector" {
  function_name    = "cqrs-projector-${var.environment}"
  role             = aws_iam_role.projector.arn
  filename         = data.archive_file.projector.output_path
  source_code_hash = data.archive_file.projector.output_base64sha256
  runtime          = "python3.12"
  handler          = "handler.handler"
  timeout          = 60

  environment {
    variables = {
      OPENSEARCH_ENDPOINT = var.opensearch_endpoint
      REDIS_ENDPOINT      = var.redis_endpoint
      REDIS_PORT          = var.redis_port
    }
  }
}

# ── Event Source Mappings (DynamoDB Streams → Lambda) ────────────────────────

resource "aws_lambda_event_source_mapping" "productos_stream" {
  event_source_arn  = var.productos_stream_arn
  function_name     = aws_lambda_function.projector.arn
  starting_position = "LATEST"
  batch_size        = 100

  filter_criteria {
    filter {
      # Solo procesar eventos de INSERT y MODIFY (no REMOVE por ahora)
      pattern = jsonencode({
        eventName = ["INSERT", "MODIFY"]
      })
    }
  }
}

resource "aws_lambda_event_source_mapping" "stock_stream" {
  event_source_arn  = var.stock_stream_arn
  function_name     = aws_lambda_function.projector.arn
  starting_position = "LATEST"
  batch_size        = 100
}

output "projector_arn" { value = aws_lambda_function.projector.arn }
