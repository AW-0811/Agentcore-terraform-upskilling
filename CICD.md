# Set up the AWS delivery pipeline

This guide is for deploying your own copy of the agent from a GitHub repository you control. It assumes the agent runtime has already been deployed once. The AWS deployment flow is AWS CodePipeline coordinating AWS CodeBuild; GitHub Actions separately runs repository CI. AWS credentials are not stored in GitHub.

## How releases work

1. A push to your configured branch is fetched through AWS CodeConnections.
2. CodeBuild installs the pinned tools, runs Python checks and tests, builds the Linux ARM64 package, validates Terraform, and creates a saved Terraform plan.
3. A release guard rejects unapproved infrastructure actions. The pipeline pauses so a person can inspect and approve the plan.
4. A second CodeBuild job applies that exact saved plan and runs two smoke requests against the runtime.

The pipeline's manual approval is intentional. It is possible to remove it later, but auto-apply is only appropriate after you understand the plan guard, have isolated test and production environments, and have a reliable rollback process.

## Before you start

- AWS CLI v2, Terraform **1.14.5**, Python 3.13, and `uv`.
- AWS credentials for the target project with permissions to create the listed resources.
- Your own GitHub repository and permission to authorize the AWS CodeConnections GitHub App.
- An AgentCore runtime deployed from this repository, with the expected runtime IAM role and Secrets Manager secret.
- A plan review before every Terraform apply. The state bucket, pipeline, CodeBuild, CloudWatch, S3, and AgentCore usage may incur charges.

The Terraform roots currently target `us-east-2`. To use another selected Region, consistently change the provider and backend Region settings in the application, `bootstrap/`, and `cicd/`; then use that Region for AWS CLI and console operations.

## 1. Sign in and check the target

Use the sign-in method configured for your AWS project. Then set the profile and Region for this terminal and confirm the identity before proceeding:

```powershell
$env:AWS_PROFILE = 'your-aws-profile'
$env:AWS_DEFAULT_REGION = 'us-east-2'
aws sts get-caller-identity --region $env:AWS_DEFAULT_REGION
```

The displayed identity must belong to the AWS project where you intend to deploy. Do not use another person's local profile or Terraform state.

## 2. Create the protected Terraform state bucket

The `bootstrap/` root creates a private, versioned S3 bucket with server-side encryption, a TLS-only bucket policy, and deletion protection. Its own state remains local, so do not delete the bootstrap folder's local state after applying.

```powershell
terraform -chdir=bootstrap init
terraform -chdir=bootstrap fmt -check
terraform -chdir=bootstrap validate
terraform -chdir=bootstrap plan -out=bootstrap.tfplan
terraform -chdir=bootstrap show bootstrap.tfplan
terraform -chdir=bootstrap apply bootstrap.tfplan
$stateBucket = terraform -chdir=bootstrap output -raw state_bucket_name
```

Confirm the plan creates only the state bucket protections. Back up `bootstrap/terraform.tfstate` securely; state may contain sensitive values. Never commit it.

## 3. Initialize app state and deploy the app

Create the Secrets Manager secret expected by `main.tf` (`incident-triage-demo/openai`) with JSON field `OPENAI_API_KEY`. The API key must not be placed in Terraform variables, source control, build output, or shell history.

```powershell
uv sync --locked
uv run --locked pytest -q
uv run --locked python build.py
terraform init -backend-config="bucket=$stateBucket"
terraform plan -out=app.tfplan
terraform show app.tfplan
```

For a first deployment, review the plan and confirm it creates only the expected app resources. For an existing deployment, ensure you have its correct state and that the plan does not create a duplicate runtime. Apply only after this review:

```powershell
terraform apply app.tfplan
terraform output -raw runtime_arn
terraform output -raw artifact_bucket_name
```

Back up the local state securely before migrating it to S3. If resources already exist, import them or migrate their owning state; do not create duplicate resources by pointing a fresh state at an existing deployment.

## 4. Configure your GitHub repository

Push this project to the default branch of a repository you control. In `cicd/variables.tf`, set `github_owner`, `github_repository`, and `github_branch` to match your repository. Defaults are examples only.

Initialize the CI/CD root with the same state bucket, then create a local ignored variables file from the example:

```powershell
terraform -chdir=cicd init -backend-config="bucket=$stateBucket"
Copy-Item cicd/terraform.tfvars.example cicd/terraform.tfvars
```

Fill in `state_bucket_name`, `app_artifact_bucket_name`, and `agent_runtime_arn` using the outputs from the bootstrap and app roots. Keep `terraform.tfvars` local; it is ignored by Git.

Create and review the pipeline plan:

```powershell
terraform -chdir=cicd plan -out=../pipeline.tfplan
terraform -chdir=cicd show ..\pipeline.tfplan
```

Confirm the plan creates the CI/CD resources and does not modify or replace your AgentCore runtime. Then apply the saved plan:

```powershell
terraform -chdir=cicd apply ..\pipeline.tfplan
```

## 5. Authorize the AWS connection and test a release

The connection starts in `PENDING`. In AWS Console, open **Developer Tools → Settings → Connections**, select `incident-triage-github`, and authorize your repository. Wait until the connection is `AVAILABLE`.

Push a small change. GitHub Actions should run CI, then the AWS pipeline should fetch the commit, build and test it, and create a Terraform plan. Inspect the plan and guard result before approving. The apply stage uses the saved reviewed plan and runs both live smoke cases; expected statuses are `incident: ok` and `tool_failure: evidence_unavailable`.

## Account and state separation

Each deployer should use a separate AWS project/account and a separate state bucket. Do not share Terraform state between independent installations. The application, bootstrap, and pipeline Terraform roots use separate state keys within one installation's bucket. Treat the state bucket as sensitive infrastructure and preserve its versioning and deletion protection.
