variable "environment"        { type = string }
variable "productos_table_name"{ type = string }
variable "stock_table_name"    { type = string }
variable "opensearch_endpoint" { type = string }

# ── OpenSearch (Elasticsearch) ────────────────────────────────────────────────

resource "aws_opensearch_domain" "productos" {
  domain_name    = "productos-${var.environment}"
  engine_version = "OpenSearch_2.11"

  cluster_config {
    instance_type  = "t3.small.search"
    instance_count = 1
  }

  ebs_options {
    ebs_enabled = true
    volume_size = 10 # GB
  }

  encrypt_at_rest {
    enabled = true
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https = true
  }

  tags = { Environment = var.environment }
}

# ── ElastiCache (Redis) ───────────────────────────────────────────────────────

resource "aws_elasticache_cluster" "cache" {
  cluster_id           = "productos-${var.environment}"
  engine               = "redis"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  engine_version       = "7.0"
  port                 = 6379

  tags = { Environment = var.environment }
}

# ── IAM para Lambda query handler ─────────────────────────────────────────────

resource "aws_iam_role" "query_lambda" {
  name = "cqrs-query-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "query_lambda" {
  role = aws_iam_role.query_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query"]
        Resource = [
          "arn:aws:dynamodb:*:*:table/${var.productos_table_name}",
          "arn:aws:dynamodb:*:*:table/${var.stock_table_name}",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["es:ESHttpGet", "es:ESHttpPost"]
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

# ── Lambda: query handler ─────────────────────────────────────────────────────

data "archive_file" "query" {
  type        = "zip"
  output_path = "/tmp/cqrs-query.zip"
  source {
    content  = <<-PYTHON
      import json, boto3, os
      from urllib.request import Request, urlopen
      from urllib.parse import urlencode

      ddb = boto3.client('dynamodb')

      def handler(event, context):
          path   = event['path']
          params = event.get('queryStringParameters', {}) or {}

          if '/search' in path:
              q = params.get('q', '')
              return buscar_opensearch(q, params)
          elif '/categoria/' in path:
              categoria = path.split('/')[-1]
              return listar_por_categoria(categoria)
          elif '/productos/' in path and path.count('/') == 2:
              producto_id = path.split('/')[-1]
              return obtener_producto(producto_id)
          return {'statusCode': 404, 'body': 'Not found'}

      def buscar_opensearch(q, params):
          """Búsqueda full-text con filtros opcionales"""
          endpoint = os.environ['OPENSEARCH_ENDPOINT']
          query = {
              "query": {
                  "bool": {
                      "must": [{"multi_match": {"query": q, "fields": ["nombre^3", "descripcion", "categoria"]}}],
                      "filter": []
                  }
              },
              "size": 20
          }
          # Filtro por precio si se especifica
          if 'precio_max' in params:
              query["query"]["bool"]["filter"].append(
                  {"range": {"precio": {"lte": float(params['precio_max'])}}}
              )

          url = f"https://{endpoint}/productos/_search"
          req = Request(url, data=json.dumps(query).encode(), method='POST')
          req.add_header('Content-Type', 'application/json')
          resp = json.loads(urlopen(req).read())
          hits = [h['_source'] for h in resp['hits']['hits']]
          return {'statusCode': 200, 'body': json.dumps(hits)}

      def listar_por_categoria(categoria):
          """Lista productos por categoría — podría estar en Redis cache"""
          # En prod: intentar Redis primero, fallback a DynamoDB
          response = ddb.query(
              TableName=os.environ['PRODUCTOS_TABLE'],
              IndexName='categoria-ts-index',
              KeyConditionExpression='categoria = :cat',
              ExpressionAttributeValues={':cat': {'S': categoria}},
              Limit=50
          )
          productos = [deserialize(item) for item in response.get('Items', [])]
          return {'statusCode': 200, 'body': json.dumps(productos)}

      def obtener_producto(producto_id):
          """Detalle de producto — directamente de DynamoDB (consistency)"""
          response = ddb.get_item(
              TableName=os.environ['PRODUCTOS_TABLE'],
              Key={'producto_id': {'S': producto_id}}
          )
          if 'Item' not in response:
              return {'statusCode': 404, 'body': 'Producto no encontrado'}
          return {'statusCode': 200, 'body': json.dumps(deserialize(response['Item']))}

      def deserialize(item):
          result = {}
          for k, v in item.items():
              if 'S' in v: result[k] = v['S']
              elif 'N' in v: result[k] = float(v['N'])
          return result
    PYTHON
    filename = "handler.py"
  }
}

resource "aws_lambda_function" "query" {
  function_name    = "cqrs-query-${var.environment}"
  role             = aws_iam_role.query_lambda.arn
  filename         = data.archive_file.query.output_path
  source_code_hash = data.archive_file.query.output_base64sha256
  runtime          = "python3.12"
  handler          = "handler.handler"
  timeout          = 10

  environment {
    variables = {
      PRODUCTOS_TABLE     = var.productos_table_name
      OPENSEARCH_ENDPOINT = var.opensearch_endpoint
      REDIS_ENDPOINT      = aws_elasticache_cluster.cache.cache_nodes[0].address
    }
  }
}

output "opensearch_endpoint" { value = aws_opensearch_domain.productos.endpoint }
output "redis_endpoint"      { value = aws_elasticache_cluster.cache.cache_nodes[0].address }
output "query_lambda_arn"    { value = aws_lambda_function.query.arn }
