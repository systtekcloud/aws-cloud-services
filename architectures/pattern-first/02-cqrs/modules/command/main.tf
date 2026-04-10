variable "environment" { type = string }

# ── DynamoDB (write store — source of truth) ──────────────────────────────────

resource "aws_dynamodb_table" "productos" {
  name         = "productos-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "producto_id"

  attribute {
    name = "producto_id"
    type = "S"
  }

  attribute {
    name = "categoria"
    type = "S"
  }

  attribute {
    name = "ts_modificado"
    type = "S"
  }

  # Para queries por categoría en el write side (admin)
  global_secondary_index {
    name            = "categoria-ts-index"
    hash_key        = "categoria"
    range_key       = "ts_modificado"
    projection_type = "ALL"
  }

  # DynamoDB Streams: necesario para el projector
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  tags = { Environment = var.environment }
}

resource "aws_dynamodb_table" "stock" {
  name         = "stock-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "producto_id"

  attribute {
    name = "producto_id"
    type = "S"
  }

  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  tags = { Environment = var.environment }
}

# ── IAM para Lambda command handlers ─────────────────────────────────────────

resource "aws_iam_role" "command_lambda" {
  name = "cqrs-command-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "command_lambda" {
  role = aws_iam_role.command_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem", "dynamodb:DeleteItem"]
        Resource = [aws_dynamodb_table.productos.arn, aws_dynamodb_table.stock.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# ── Lambda: command handler (crear/actualizar producto) ───────────────────────

data "archive_file" "command" {
  type        = "zip"
  output_path = "/tmp/cqrs-command.zip"
  source {
    content  = <<-PYTHON
      import json, boto3, os, uuid
      from datetime import datetime, timezone

      ddb = boto3.client('dynamodb')

      def handler(event, context):
          method = event['httpMethod']
          path   = event['path']
          body   = json.loads(event.get('body', '{}'))

          if method == 'POST' and path == '/productos':
              return crear_producto(body)
          elif method == 'PUT' and '/stock/' in path:
              producto_id = path.split('/')[-1]
              return actualizar_stock(producto_id, body)
          return {'statusCode': 404, 'body': 'Not found'}

      def crear_producto(body):
          producto_id = str(uuid.uuid4())
          ahora = datetime.now(timezone.utc).isoformat()

          ddb.put_item(
              TableName=os.environ['PRODUCTOS_TABLE'],
              Item={
                  'producto_id':   {'S': producto_id},
                  'nombre':        {'S': body['nombre']},
                  'categoria':     {'S': body['categoria']},
                  'precio':        {'N': str(body['precio'])},
                  'descripcion':   {'S': body.get('descripcion', '')},
                  'ts_creado':     {'S': ahora},
                  'ts_modificado': {'S': ahora},
                  'version':       {'N': '1'},
              },
              ConditionExpression='attribute_not_exists(producto_id)'
          )
          return {
              'statusCode': 201,
              'body': json.dumps({'producto_id': producto_id})
          }

      def actualizar_stock(producto_id, body):
          delta = int(body.get('delta', 0))  # +5 = añadir, -1 = vender
          ddb.update_item(
              TableName=os.environ['STOCK_TABLE'],
              Key={'producto_id': {'S': producto_id}},
              UpdateExpression='ADD stock :d SET ts_modificado = :ts',
              ConditionExpression='stock + :d >= :cero',  # no stock negativo
              ExpressionAttributeValues={
                  ':d':    {'N': str(delta)},
                  ':ts':   {'S': datetime.now(timezone.utc).isoformat()},
                  ':cero': {'N': '0'},
              }
          )
          return {'statusCode': 200, 'body': json.dumps({'ok': True})}
    PYTHON
    filename = "handler.py"
  }
}

resource "aws_lambda_function" "command" {
  function_name    = "cqrs-command-${var.environment}"
  role             = aws_iam_role.command_lambda.arn
  filename         = data.archive_file.command.output_path
  source_code_hash = data.archive_file.command.output_base64sha256
  runtime          = "python3.12"
  handler          = "handler.handler"
  timeout          = 10

  environment {
    variables = {
      PRODUCTOS_TABLE = aws_dynamodb_table.productos.name
      STOCK_TABLE     = aws_dynamodb_table.stock.name
    }
  }
}

output "productos_table_arn"        { value = aws_dynamodb_table.productos.arn }
output "productos_table_name"       { value = aws_dynamodb_table.productos.name }
output "productos_stream_arn"       { value = aws_dynamodb_table.productos.stream_arn }
output "stock_table_arn"            { value = aws_dynamodb_table.stock.arn }
output "stock_table_name"           { value = aws_dynamodb_table.stock.name }
output "stock_stream_arn"           { value = aws_dynamodb_table.stock.stream_arn }
output "command_lambda_arn"         { value = aws_lambda_function.command.arn }
