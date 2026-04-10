variable "environment"        { type = string }
variable "shard_count"        { type = number default = 1 }
variable "sns_topic_arn"      { type = string }
variable "dynamodb_table_arn" { type = string }
variable "dynamodb_table_name"{ type = string }
variable "firehose_arn"       { type = string }

# ── Kinesis Data Streams ──────────────────────────────────────────────────────

resource "aws_kinesis_stream" "sensors" {
  name             = "sensors-${var.environment}"
  shard_count      = var.shard_count
  retention_period = 168 # 7 días (máximo sin coste adicional)

  stream_mode_details {
    stream_mode = var.shard_count == 0 ? "ON_DEMAND" : "PROVISIONED"
  }

  encryption_type = "KMS"
  kms_key_id      = "alias/aws/kinesis"

  tags = { Environment = var.environment }
}

# ── IAM para Lambdas ──────────────────────────────────────────────────────────

resource "aws_iam_role" "lambda" {
  name = "iot-lambda-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kinesis:GetRecords", "kinesis:GetShardIterator", "kinesis:DescribeStream", "kinesis:ListShards"]
        Resource = aws_kinesis_stream.sensors.arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem"]
        Resource = [var.dynamodb_table_arn, "${var.dynamodb_table_arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["firehose:PutRecordBatch"]
        Resource = var.firehose_arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = var.sns_topic_arn
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# ── Lambda: procesador de stream (Kinesis → DynamoDB + Firehose) ──────────────

data "archive_file" "processor" {
  type        = "zip"
  output_path = "/tmp/iot-processor.zip"
  source {
    content  = <<-PYTHON
      import json, boto3, base64, os, time

      ddb      = boto3.client('dynamodb')
      firehose = boto3.client('firehose')
      cw       = boto3.client('cloudwatch')

      def handler(event, context):
          records_for_firehose = []

          for record in event['Records']:
              # Kinesis records are base64 encoded
              payload = json.loads(base64.b64decode(record['kinesis']['data']))
              device_id = payload.get('device_id', 'unknown')
              temp      = payload.get('temp', 0)
              ts        = payload.get('ts', int(time.time()))

              # 1. Upsert en DynamoDB (última lectura por sensor)
              ddb.put_item(
                  TableName=os.environ['DYNAMODB_TABLE'],
                  Item={
                      'device_id':   {'S': device_id},
                      'zone_id':     {'S': payload.get('zone_id', 'unknown')},
                      'temp':        {'N': str(temp)},
                      'ts_ultimo':   {'N': str(ts)},
                      'status':      {'S': 'alerta' if temp > 85 else 'normal'},
                  }
              )

              # 2. Preparar para Firehose (añadir newline — Athena lo requiere)
              records_for_firehose.append({
                  'Data': (json.dumps(payload) + '\n').encode('utf-8')
              })

          # 3. Enviar batch a Firehose
          if records_for_firehose:
              firehose.put_record_batch(
                  DeliveryStreamName=os.environ['FIREHOSE_STREAM'],
                  Records=records_for_firehose
              )

          # 4. Métrica custom
          cw.put_metric_data(
              Namespace='IoT/Pipeline',
              MetricData=[{
                  'MetricName': 'RecordsProcessed',
                  'Value': len(event['Records']),
                  'Unit': 'Count'
              }]
          )

          return {'statusCode': 200}
    PYTHON
    filename = "handler.py"
  }
}

resource "aws_lambda_function" "processor" {
  function_name    = "iot-processor-${var.environment}"
  role             = aws_iam_role.lambda.arn
  filename         = data.archive_file.processor.output_path
  source_code_hash = data.archive_file.processor.output_base64sha256
  runtime          = "python3.12"
  handler          = "handler.handler"
  timeout          = 60

  environment {
    variables = {
      DYNAMODB_TABLE  = var.dynamodb_table_name
      FIREHOSE_STREAM = split("/", var.firehose_arn)[1]
    }
  }
}

resource "aws_lambda_event_source_mapping" "kinesis" {
  event_source_arn              = aws_kinesis_stream.sensors.arn
  function_name                 = aws_lambda_function.processor.arn
  starting_position             = "LATEST"
  batch_size                    = 100
  bisect_batch_on_function_error = true
  parallelization_factor        = 1 # escala a 10 con más shards
}

# ── Lambda: alertas de temperatura ───────────────────────────────────────────

data "archive_file" "alerter" {
  type        = "zip"
  output_path = "/tmp/iot-alerter.zip"
  source {
    content  = <<-PYTHON
      import json, boto3, os, time

      sns = boto3.client('sns')
      ddb = boto3.client('dynamodb')

      COOLDOWN_SECONDS = 300  # 5 minutos entre alertas del mismo sensor

      def handler(event, context):
          device_id = event.get('device_id', 'unknown')
          temp      = event.get('temp', 0)

          # Verificar cooldown
          response = ddb.get_item(
              TableName=os.environ['DYNAMODB_TABLE'],
              Key={'device_id': {'S': device_id}},
              ProjectionExpression='ts_ultima_alerta'
          )
          item = response.get('Item', {})
          ts_ultima = int(item.get('ts_ultima_alerta', {}).get('N', 0))
          now = int(time.time())

          if (now - ts_ultima) < COOLDOWN_SECONDS:
              print(f"Cooldown activo para {device_id}, skip")
              return

          # Publicar alerta
          sns.publish(
              TopicArn=os.environ['SNS_TOPIC_ARN'],
              Subject=f"ALERTA: Temperatura crítica en {device_id}",
              Message=json.dumps({
                  'device_id': device_id,
                  'temp': temp,
                  'zona': event.get('zone_id', 'unknown'),
                  'ts': event.get('ts', now),
                  'mensaje': f"Temperatura {temp}°C supera umbral 85°C"
              }),
              MessageAttributes={
                  'tipo': {'DataType': 'String', 'StringValue': 'alerta_temperatura'}
              }
          )

          # Actualizar timestamp de última alerta
          ddb.update_item(
              TableName=os.environ['DYNAMODB_TABLE'],
              Key={'device_id': {'S': device_id}},
              UpdateExpression='SET ts_ultima_alerta = :ts',
              ExpressionAttributeValues={':ts': {'N': str(now)}}
          )
    PYTHON
    filename = "handler.py"
  }
}

resource "aws_lambda_function" "alerter" {
  function_name    = "iot-alerter-${var.environment}"
  role             = aws_iam_role.lambda.arn
  filename         = data.archive_file.alerter.output_path
  source_code_hash = data.archive_file.alerter.output_base64sha256
  runtime          = "python3.12"
  handler          = "handler.handler"
  timeout          = 15

  environment {
    variables = {
      DYNAMODB_TABLE = var.dynamodb_table_name
      SNS_TOPIC_ARN  = var.sns_topic_arn
    }
  }
}

output "stream_arn"      { value = aws_kinesis_stream.sensors.arn }
output "stream_name"     { value = aws_kinesis_stream.sensors.name }
output "processor_arn"   { value = aws_lambda_function.processor.arn }
output "alerter_arn"     { value = aws_lambda_function.alerter.arn }
