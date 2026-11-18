terraform {
  required_version = "1.14.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = local.region
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_secretsmanager_secret" "openai" {
  name = "incident-triage-demo/openai"
}

locals {
  region       = "us-east-2"
  account      = data.aws_caller_identity.current.account_id
  partition    = data.aws_partition.current.partition
  runtime_name = "incident_triage_demo"
  log_group    = "arn:${local.partition}:logs:${local.region}:${local.account}:log-group:/aws/bedrock-agentcore/runtimes/${local.runtime_name}-*"
  artifact     = "${path.module}/dist/agent.zip"
}

resource "aws_s3_bucket" "artifact" {
  bucket_prefix = "bedrock-agentcore-code-"
}

resource "aws_s3_bucket_public_access_block" "artifact" {
  bucket                  = aws_s3_bucket.artifact.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "agent" {
  bucket = aws_s3_bucket.artifact.id
  key    = "releases/${filesha256(local.artifact)}.zip"
  source = local.artifact

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role" "runtime" {
  name = "incident-triage-demo-runtime"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account }
        ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account}:*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "runtime" {
  name = "incident-triage-demo-runtime"
  role = aws_iam_role.runtime.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.artifact.arn}/releases/*"
      },
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = data.aws_secretsmanager_secret.openai.arn
        Condition = {
          Bool = { "aws:SecureTransport" = "true" }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:DescribeLogStreams", "logs:PutResourcePolicy"]
        Resource = local.log_group
      },
      {
        Effect   = "Allow"
        Action   = "logs:DescribeLogGroups"
        Resource = "arn:${local.partition}:logs:${local.region}:${local.account}:log-group:*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${local.log_group}:log-stream:*"
      },
      {
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "cloudwatch:PutMetricData"
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = "bedrock-agentcore" }
        }
      },
    ]
  })
}

resource "aws_bedrockagentcore_agent_runtime" "triage" {
  agent_runtime_name = local.runtime_name
  role_arn           = aws_iam_role.runtime.arn
  environment_variables = {
    TRIAGE_HOST              = "0.0.0.0"
    TRIAGE_OPENAI_SECRET_ARN = data.aws_secretsmanager_secret.openai.arn
  }

  agent_runtime_artifact {
    code_configuration {
      runtime     = "PYTHON_3_13"
      entry_point = ["opentelemetry-instrument", "main.py"]

      code {
        s3 {
          bucket = aws_s3_object.agent.bucket
          prefix = aws_s3_object.agent.key
        }
      }
    }
  }

  network_configuration {
    network_mode = "PUBLIC"
  }

  depends_on = [aws_iam_role_policy.runtime, aws_s3_bucket_public_access_block.artifact]
}

output "runtime_arn" {
  value = aws_bedrockagentcore_agent_runtime.triage.agent_runtime_arn
}

output "artifact_bucket_name" {
  value = aws_s3_bucket.artifact.id
}
