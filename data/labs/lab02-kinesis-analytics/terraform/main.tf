terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

# ─── KDS source ─────────────────────────────────────────────────────────────

resource "aws_kinesis_stream" "source" {
  name             = "${var.prefix}-sensor-data"
  shard_count      = var.shard_count
  retention_period = 24

  tags = var.tags
}

# ─── KDS output (para anomaly detection) ────────────────────────────────────

resource "aws_kinesis_stream" "output" {
  name             = "${var.prefix}-output"
  shard_count      = 1
  retention_period = 24

  tags = var.tags
}

# ─── IAM — KDA ──────────────────────────────────────────────────────────────

resource "aws_iam_role" "kda" {
  name = "${var.prefix}-kda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "kinesisanalytics.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "kda" {
  name = "${var.prefix}-kda-policy"
  role = aws_iam_role.kda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kinesis:GetRecords",
          "kinesis:GetShardIterator",
          "kinesis:DescribeStream",
          "kinesis:ListShards",
        ]
        Resource = aws_kinesis_stream.source.arn
      },
      {
        Effect = "Allow"
        Action = [
          "kinesis:PutRecord",
          "kinesis:PutRecords",
          "kinesis:DescribeStream",
        ]
        Resource = aws_kinesis_stream.output.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
        ]
        Resource = "*"
      },
    ]
  })
}

# ─── KDA Application ────────────────────────────────────────────────────────

resource "aws_kinesisanalyticsv2_application" "main" {
  name                   = "${var.prefix}-analytics"
  runtime_environment    = "SQL-1_0"
  service_execution_role = aws_iam_role.kda.arn

  application_configuration {
    application_code_configuration {
      code_content {
        text_content = <<-SQL
          CREATE OR REPLACE STREAM "DESTINATION_SQL_STREAM" (
              sensor_id    VARCHAR(32),
              avg_temp     DOUBLE,
              min_temp     DOUBLE,
              max_temp     DOUBLE,
              record_count BIGINT,
              window_end   TIMESTAMP
          );

          CREATE OR REPLACE PUMP "STREAM_PUMP" AS INSERT INTO "DESTINATION_SQL_STREAM"
          SELECT STREAM
              sensor_id,
              AVG(temperature)   AS avg_temp,
              MIN(temperature)   AS min_temp,
              MAX(temperature)   AS max_temp,
              COUNT(*)           AS record_count,
              STEP("SOURCE_SQL_STREAM_001".ROWTIME BY INTERVAL '1' MINUTE) AS window_end
          FROM "SOURCE_SQL_STREAM_001"
          GROUP BY
              sensor_id,
              STEP("SOURCE_SQL_STREAM_001".ROWTIME BY INTERVAL '1' MINUTE);
        SQL
      }
      code_content_type = "PLAINTEXT"
    }

    sql_application_configuration {
      input {
        name_prefix = "SOURCE_SQL_STREAM"

        kinesis_streams_input {
          resource_arn = aws_kinesis_stream.source.arn
        }

        input_schema {
          record_format {
            record_format_type = "JSON"
            mapping_parameters {
              json_mapping_parameters {
                record_row_path = "$"
              }
            }
          }

          record_column {
            name    = "sensor_id"
            sql_type = "VARCHAR(32)"
            mapping = "$.sensor_id"
          }
          record_column {
            name    = "temperature"
            sql_type = "DOUBLE"
            mapping = "$.temperature"
          }
          record_column {
            name    = "ts"
            sql_type = "VARCHAR(32)"
            mapping = "$.ts"
          }
        }

        input_starting_position_configuration {
          input_starting_position = "NOW"
        }
      }

      output {
        name = "DESTINATION_SQL_STREAM"

        kinesis_streams_output {
          resource_arn = aws_kinesis_stream.output.arn
        }

        destination_schema {
          record_format_type = "JSON"
        }
      }
    }
  }

  tags = var.tags
}
