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
  region = "us-east-2"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_secretsmanager_secret" "openai" {
  name = "incident-triage-demo/openai"
}

locals {
  account_id            = data.aws_caller_identity.current.account_id
  partition             = data.aws_partition.current.partition
  region                = "us-east-2"
  repository_full_id    = "${var.github_owner}/${var.github_repository}"
  runtime_id            = split("/", var.agent_runtime_arn)[1]
  runtime_endpoint_arn  = "${var.agent_runtime_arn}/runtime-endpoint/DEFAULT"
  runtime_log_group_arn = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/${local.runtime_id}-DEFAULT:*"
  state_bucket_arn      = "arn:${local.partition}:s3:::${var.state_bucket_name}"
  app_bucket_arn        = "arn:${local.partition}:s3:::${var.app_artifact_bucket_name}"
  codepipeline_name     = "incident-triage-release"
  plan_project_name     = "incident-triage-plan"
  apply_project_name    = "incident-triage-apply"
}

resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket_prefix = "it-pipeline-${local.account_id}-"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "pipeline_artifacts" {
  bucket                  = aws_s3_bucket.pipeline_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id

  rule {
    id     = "expire-pipeline-artifacts"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_cloudwatch_log_group" "plan" {
  name              = "/aws/codebuild/${local.plan_project_name}"
  retention_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "apply" {
  name              = "/aws/codebuild/${local.apply_project_name}"
  retention_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_codeconnections_connection" "github" {
  name          = "incident-triage-github"
  provider_type = "GitHub"
}

resource "aws_iam_role" "codepipeline" {
  name = "incident-triage-codepipeline"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:codepipeline:${local.region}:${local.account_id}:${local.codepipeline_name}" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "codepipeline" {
  name = "incident-triage-codepipeline"
  role = aws_iam_role.codepipeline.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["codeconnections:UseConnection"]
        Resource = aws_codeconnections_connection.github.arn
        Condition = {
          StringEquals = {
            "codeconnections:FullRepositoryId" = local.repository_full_id
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["s3:Get*", "s3:ListBucket"]
        Resource = aws_s3_bucket.pipeline_artifacts.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:PutObjectAcl"]
        Resource = "${aws_s3_bucket.pipeline_artifacts.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
        Resource = [aws_codebuild_project.plan.arn, aws_codebuild_project.apply.arn]
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.codebuild.arn
        Condition = {
          StringEquals = { "iam:PassedToService" = "codebuild.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_iam_role" "codebuild" {
  name = "incident-triage-codebuild"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "codebuild.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:codebuild:${local.region}:${local.account_id}:project/incident-triage-*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  name = "incident-triage-codebuild"
  role = aws_iam_role.codebuild.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetBucketAcl", "s3:GetBucketLocation", "s3:ListBucket", "s3:GetBucketVersioning"]
        Resource = [local.state_bucket_arn, local.app_bucket_arn, aws_s3_bucket.pipeline_artifacts.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketPolicy",
          "s3:GetBucketCORS",
          "s3:GetBucketWebsite",
          "s3:GetAccelerateConfiguration",
          "s3:GetBucketRequestPayment",
          "s3:GetBucketLogging",
          "s3:GetLifecycleConfiguration",
          "s3:GetReplicationConfiguration",
          "s3:GetEncryptionConfiguration",
          "s3:GetBucketObjectLockConfiguration",
          "s3:GetBucketTagging",
        ]
        Resource = local.app_bucket_arn
      },
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:DeleteObject"]
        Resource = [
          "${local.state_bucket_arn}/incident-triage-demo/terraform.tfstate",
          "${local.state_bucket_arn}/incident-triage-demo/terraform.tfstate.tflock",
          "${local.app_bucket_arn}/releases/*",
          "${aws_s3_bucket.pipeline_artifacts.arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:GetAgentRuntime",
          "bedrock-agentcore:UpdateAgentRuntime",
          "bedrock-agentcore:ListAgentRuntimeEndpoints",
          "bedrock-agentcore:GetAgentRuntimeEndpoint",
          "bedrock-agentcore:ListAgentRuntimeVersions",
          "bedrock-agentcore:InvokeAgentRuntime",
        ]
        Resource = [var.agent_runtime_arn, local.runtime_endpoint_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["bedrock-agentcore:ListAgentRuntimes"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies"]
        Resource = "arn:${local.partition}:iam::${local.account_id}:role/incident-triage-demo-runtime"
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:${local.partition}:iam::${local.account_id}:role/incident-triage-demo-runtime"
        Condition = {
          StringEquals = { "iam:PassedToService" = "bedrock-agentcore.amazonaws.com" }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:DescribeSecret", "secretsmanager:GetResourcePolicy"]
        Resource = data.aws_secretsmanager_secret.openai.arn
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:DescribeAlarms", "cloudwatch:GetDashboard", "cloudwatch:ListTagsForResource", "cloudwatch:PutDashboard", "cloudwatch:PutMetricAlarm"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups", "logs:ListTagsForResource"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:PutRetentionPolicy"]
        Resource = local.runtime_log_group_arn
      },
      {
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [
          "${aws_cloudwatch_log_group.plan.arn}:log-stream:*",
          "${aws_cloudwatch_log_group.apply.arn}:log-stream:*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_codebuild_project" "plan" {
  name          = local.plan_project_name
  description   = "Test the agent, build its ZIP, and create a guarded Terraform plan."
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 45

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    image_pull_credentials_type = "CODEBUILD"
    type                        = "LINUX_CONTAINER"

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = local.account_id
      type  = "PLAINTEXT"
    }

    environment_variable {
      name  = "TF_STATE_BUCKET"
      value = var.state_bucket_name
      type  = "PLAINTEXT"
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.plan.name
      status     = "ENABLED"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "cicd/buildspecs/plan.yml"
  }

  depends_on = [aws_iam_role_policy.codebuild]
}

resource "aws_codebuild_project" "apply" {
  name          = local.apply_project_name
  description   = "Apply the approved Terraform plan and run both live smoke cases."
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 30

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    image_pull_credentials_type = "CODEBUILD"
    type                        = "LINUX_CONTAINER"

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = local.account_id
      type  = "PLAINTEXT"
    }

    environment_variable {
      name  = "TF_STATE_BUCKET"
      value = var.state_bucket_name
      type  = "PLAINTEXT"
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.apply.name
      status     = "ENABLED"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "cicd/buildspecs/apply.yml"
  }

  depends_on = [aws_iam_role_policy.codebuild]
}

resource "aws_codepipeline" "agent_release" {
  name           = local.codepipeline_name
  role_arn       = aws_iam_role.codepipeline.arn
  pipeline_type  = "V2"
  execution_mode = "QUEUED"

  artifact_store {
    location = aws_s3_bucket.pipeline_artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["SourceOutput"]
      configuration = {
        ConnectionArn        = aws_codeconnections_connection.github.arn
        FullRepositoryId     = local.repository_full_id
        BranchName           = var.github_branch
        OutputArtifactFormat = "CODE_ZIP"
      }
    }
  }

  stage {
    name = "Plan"

    action {
      name             = "TestAndPlan"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["SourceOutput"]
      output_artifacts = ["ReleasePlan"]
      configuration = {
        ProjectName = aws_codebuild_project.plan.name
      }
    }
  }

  stage {
    name = "Approve"

    action {
      name     = "ReviewTerraformPlan"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"
      configuration = {
        CustomData = "Review the guarded plan in the Plan stage logs. Approval allows Terraform to update the existing AgentCore runtime. Reject if the plan proposes creating or replacing that runtime."
      }
    }
  }

  stage {
    name = "Apply"

    action {
      name            = "ApplyAndSmokeTest"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["ReleasePlan"]
      configuration = {
        ProjectName = aws_codebuild_project.apply.name
      }
    }
  }

  trigger {
    provider_type = "CodeStarSourceConnection"

    git_configuration {
      source_action_name = "Source"

      push {
        branches {
          includes = [var.github_branch]
        }
      }
    }
  }

  depends_on = [aws_iam_role_policy.codepipeline]
}

output "pipeline_name" {
  value = aws_codepipeline.agent_release.name
}

output "github_connection_arn" {
  value = aws_codeconnections_connection.github.arn
}

output "github_connection_status" {
  value = aws_codeconnections_connection.github.connection_status
}

output "artifact_bucket_name" {
  value = aws_s3_bucket.pipeline_artifacts.id
}
