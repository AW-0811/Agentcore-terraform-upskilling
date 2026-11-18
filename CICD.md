# GitHub CI and AWS delivery pipeline

## How the pieces fit

- GitHub Actions runs pull-request checks without AWS credentials.
- AWS CodePipeline watches `AW-0811/Agentcore-terraform-upskilling` on `main` through CodeConnections.
- CodeBuild runs the tests, builds the Linux ARM64 agent ZIP, initializes the shared Terraform state, and creates a plan.
- The pipeline pauses at a manual approval action. After approval, CodeBuild applies the saved plan and runs the two live smoke cases.
- Terraform defines the state bucket, CodeConnections link, pipeline roles, artifact storage, CodeBuild projects, and CodePipeline.

Terraform declares and changes infrastructure; CodePipeline coordinates the stages and CodeBuild runs Terraform commands. This keeps the AWS pipeline configuration in Terraform and avoids putting AWS credentials in GitHub.

## Why this uses CodePipeline for AWS deployment

This AWS project explicitly denies IAM OIDC provider actions (`iam:*Provider*`), so GitHub Actions cannot federate directly into an AWS deployment role. The project supports CodePipeline and CodeConnections. CodeConnections uses a GitHub App authorization that you complete in the AWS Console.

The `aws_codeconnections_connection` resource is created as `PENDING`. In AWS Console, open **Developer Tools → Settings → Connections**, choose the pending `incident-triage-github` connection, and finish the GitHub App authorization for this repository. Confirm it becomes `AVAILABLE` before starting a pipeline execution.

## Terraform state

`bootstrap/` creates a private, versioned S3 bucket with server-side encryption and a TLS-only bucket policy. Its own state stays local and is ignored by Git. The application and `cicd/` Terraform roots store their state in separate keys in that bucket and use native S3 lock files. Keep the state bucket; the bootstrap resource has `prevent_destroy` enabled.

The CodePipeline artifact bucket is private and encrypted with S3-managed encryption. Pipeline artifacts expire after 30 days. CodeBuild log groups retain logs for 30 days and use CloudWatch Logs encryption at rest.

## Local AWS authentication

Keep `agentcore-test` signed in with `aws login`. Terraform 1.14.5's S3 backend does not read that newer console-login cache directly. AWS recommends a `credential_process` profile for older development tools. Create `agentcore-terraform` once, pointing to the existing short-lived session; this does not create or store static AWS keys:

```powershell
$awsExe = (Get-Command aws.exe -ErrorAction SilentlyContinue).Source
if (-not $awsExe) { $awsExe = Join-Path $env:LOCALAPPDATA 'Programs\Amazon\AWSCLIV2\aws.exe' }
aws configure set profile.agentcore-terraform.credential_process "`"$awsExe`" configure export-credentials --profile agentcore-test --format process"
aws configure set profile.agentcore-terraform.region us-east-2
$env:AWS_PROFILE = 'agentcore-terraform'
```

The CLI still uses `agentcore-test` when called with that profile; use `agentcore-terraform` for local Terraform commands so both the S3 backend and AWS provider can obtain temporary credentials.

## Release safety

The CodeBuild plan stage writes `release.tfplan` into a private pipeline artifact and runs `scripts/check_release_plan.py`. The guard allows updates to the existing runtime and the expected ZIP replacement. It rejects creation or replacement of `aws_bedrockagentcore_agent_runtime.triage`, changes to the execution role, and other unapproved resource actions. Apply runs only after a person approves the plan stage.

The apply stage uses that saved plan, waits for Terraform to finish, then runs `smoke.py` against the runtime ARN in Terraform output. Expected results are `incident: ok` and `tool_failure: evidence_unavailable`.

## First-time setup sequence

1. Set `$env:AWS_PROFILE = 'agentcore-terraform'` and `$env:AWS_DEFAULT_REGION = 'us-east-2'`. In `bootstrap/`, review and apply a Terraform plan. This creates only the protected remote-state bucket.
2. Back up `terraform.tfstate`, then set `$stateBucket = terraform -chdir=bootstrap output -raw state_bucket_name`. In the application root, run `terraform init -migrate-state -backend-config="bucket=$stateBucket"`. Terraform will ask to copy the existing local state; confirm only after verifying the backup exists.
3. In the application root, run `terraform plan`. It should show the new `artifact_bucket_name` output and no resource changes. Apply to save the output in the migrated state. Then initialize `cicd/` with `terraform -chdir=cicd init -backend-config="bucket=$stateBucket"`.
4. Copy `cicd/terraform.tfvars.example` to the ignored `cicd/terraform.tfvars` and fill in the state bucket name plus `terraform output -raw artifact_bucket_name` and `terraform output -raw runtime_arn`. Create `.tools/` if needed. Run and review `terraform -chdir=cicd plan -out=..\.tools\cicd.tfplan`; it should add pipeline resources without changing the existing AgentCore runtime. Apply only after reviewing that plan.
5. The GitHub connection will start as `PENDING`. In AWS Console, open **Developer Tools → Settings → Connections**, select `incident-triage-github`, and authorize the `AW-0811/Agentcore-terraform-upskilling` repository. Wait for status `AVAILABLE`.
6. Review the local Git commit and staged filenames, then push to the repository's `main` branch. GitHub Actions verifies the change and CodePipeline creates a Terraform plan. Review the CodeBuild plan log and approval details in CodePipeline; approve only if the guard passes and the existing runtime is updated in place.

The state and artifact buckets, CodePipeline executions, CodeBuild minutes, and CloudWatch Logs can incur AWS charges. No dedicated KMS key is used, avoiding its recurring monthly key charge. Review the AWS plan and account credits before applying the pipeline infrastructure.
