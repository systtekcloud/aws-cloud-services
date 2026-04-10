variable "environment"       { type = string }
variable "kinesis_stream_arn" { type = string }
variable "alert_lambda_arn"   { type = string }

# ── IoT Core Policy ───────────────────────────────────────────────────────────

resource "aws_iot_policy" "sensor" {
  name = "sensor-policy-${var.environment}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["iot:Connect"]
        Resource = "arn:aws:iot:*:*:client/$${iot:ClientId}"
      },
      {
        Effect   = "Allow"
        Action   = ["iot:Publish"]
        Resource = "arn:aws:iot:*:*:topic/sensors/$${iot:ClientId}/telemetry"
      }
    ]
  })
}

# ── IAM Role para IoT Core Rules ─────────────────────────────────────────────

resource "aws_iam_role" "iot_rules" {
  name = "iot-rules-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "iot.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "iot_rules" {
  role = aws_iam_role.iot_rules.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kinesis:PutRecord"]
        Resource = var.kinesis_stream_arn
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = var.alert_lambda_arn
      }
    ]
  })
}

# ── IoT Topic Rules ───────────────────────────────────────────────────────────

# Regla 1: todos los mensajes → Kinesis
resource "aws_iot_topic_rule" "telemetry_to_kinesis" {
  name        = "telemetry_kinesis_${var.environment}"
  enabled     = true
  sql         = "SELECT *, topic(2) as device_id, timestamp() as ingested_at FROM 'sensors/+/telemetry'"
  sql_version = "2016-03-23"

  kinesis {
    role_arn    = aws_iam_role.iot_rules.arn
    stream_name = split("/", var.kinesis_stream_arn)[1]
    partition_key = "$${device_id}"
  }

  error_action {
    cloudwatch_logs {
      log_group_name = "/aws/iot/errors/${var.environment}"
      role_arn       = aws_iam_role.iot_rules.arn
    }
  }
}

# Regla 2: temperatura > 85°C → Lambda alerta
resource "aws_iot_topic_rule" "temp_alert" {
  name        = "temp_alert_${var.environment}"
  enabled     = true
  sql         = "SELECT device_id, zone_id, temp, timestamp() as ts FROM 'sensors/+/telemetry' WHERE temp > 85"
  sql_version = "2016-03-23"

  lambda {
    function_arn = var.alert_lambda_arn
  }

  error_action {
    cloudwatch_logs {
      log_group_name = "/aws/iot/errors/${var.environment}"
      role_arn       = aws_iam_role.iot_rules.arn
    }
  }
}

# Permiso para IoT Core invocar Lambda
resource "aws_lambda_permission" "iot" {
  statement_id  = "allow-iot-invoke"
  action        = "lambda:InvokeFunction"
  function_name = var.alert_lambda_arn
  principal     = "iot.amazonaws.com"
}

output "iot_policy_arn" { value = aws_iot_policy.sensor.arn }
