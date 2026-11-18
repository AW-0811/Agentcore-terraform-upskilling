# Set up Terraform CI/CD for the incident triage agent

> **Status:** historical planning notes. The implementation is now in [CICD.md](CICD.md). Do not use the GitHub OIDC deployment steps in this document: this AWS project blocks IAM OIDC provider actions. The current design uses GitHub Actions for CI and AWS CodePipeline/CodeBuild for deployment.

This is the handoff for adding GitHub Actions to the existing AgentCore demo. **CI** checks each proposed change. **CD** releases a checked ZIP to the AWS runtime and runs the two live smoke cases. [GitHub Actions workflow triggers](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows) · [Terraform in GitHub Actions](https://developer.hashicorp.com/terraform/tutorials/automation/github-actions)

## Starting point

| Piece | Where to look |
| --- | --- |
| AWS project | Ohio (`us-east-2`), using `agentcore-test` for local AWS access |
| Existing deployment | `incident_triage_demo`, `DEFAULT`, last verified live on version 3. See [the deployment evidence](flow.md#11-deploy-and-verify-the-openai-agents-sdk-release). |
| Agent | `main.py` is the AgentCore entry point. `triage.py` reads sample evidence before the model step. The local source uses the OpenAI Agents SDK with GPT-6 Luna at medium reasoning. |
| Release files | `build.py` writes `dist/agent.zip`. `main.tf` uploads it and updates the existing runtime. |
| Credentials | The deployed agent reads `incident-triage-demo/openai` from Secrets Manager through its execution role. The local model test uses the ignored `.env`. |
| Pins | Python 3.13 and Terraform 1.14.5. Keep `uv.lock` and `.terraform.lock.hcl` in Git. |
| Missing setup | The folder has no first commit, Git remote, or workflows yet. The live infrastructure is tracked in the local `terraform.tfstate`. |

The workflow and backend examples below are templates for the next setup session. Start with CI. For CD, confirm the GitHub repository, get approval for the state bucket and OIDC role, and keep the current AWS project and Free plan.

The updated SDK passed the local unit tests, offline and live HTTP smoke cases, and the Linux ZIP build. The workflow examples passed local YAML and Bash checks, including simulated release-plan and endpoint-readiness checks. The first GitHub run and the AWS plan-only release are the next end-to-end checks.

## 1. Put the project on GitHub

1. Create an empty GitHub repo in the intended user or organization. Choose the visibility with the owner. The examples use `main` as the default branch.
2. Check the working tree. Stage the app, tests, workflow, docs, and the tool lockfiles. Keep `.env`, `.tools/`, `.venv/`, `dist/`, AWS config, and Terraform state and plan files outside Git. Review the staged filenames before pushing. Stage `.env.example` only after checking that its values are placeholders.
3. Prepare Terraform provider checksums for the Windows laptop and Linux runner. Use the existing pinned Terraform binary from this folder.

```powershell
terraform providers lock -platform=windows_amd64 -platform=linux_amd64
git status --short
git check-ignore .env terraform.tfstate
git add -- .gitignore .python-version .terraform-version .terraform.lock.hcl uv.lock
git add -- main.py triage.py smoke.py test_triage.py build.py main.tf pyproject.toml README.md THINGS_TO_EXPLORE.md flow.md 'setup terraform cicid.md'
# Run this after saving the CI template from step 2.
git add -- .github/workflows/ci.yml
git diff --cached --name-only
git commit -m "Add incident triage agent and CI"
git branch -M main
git remote add origin https://github.com/OWNER/REPO.git
git push -u origin main
```

On this Windows machine the Terraform executable is `.tools/terraform-1.14.5/terraform.exe` if Terraform is absent from PATH. After the first CI run succeeds, enable branch protection or a ruleset for `main` if supported by the repository plan. Require the `verify` check so releases come from reviewed code. [Provider lock settings](https://developer.hashicorp.com/terraform/cli/commands/providers/lock) · [GitHub status checks](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)

## 2. Add CI

Save this as `.github/workflows/ci.yml` before the first push. `workflow_call` also lets the release workflow run the same checks. Provider plugins come from the Terraform Registry. The backend is disabled during validation, so the job can run without AWS credentials. [Terraform validate](https://developer.hashicorp.com/terraform/cli/commands/validate) · [Astral setup-uv](https://github.com/astral-sh/setup-uv) · [HashiCorp setup-terraform](https://github.com/hashicorp/setup-terraform)

```yaml
name: Verify agent

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_call:

permissions:
  contents: read

jobs:
  verify:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - uses: astral-sh/setup-uv@68559e99cc807c1eb7e9238fd43a15bba460eec2 # v10.3.3
        with:
          version: "0.10.0"
      - uses: hashicorp/setup-terraform@v4
        with:
          terraform_version: "1.14.5"
          terraform_wrapper: false
      - name: Check Python
        run: |
          uv sync --locked
          uv run --locked ruff format --check .
          uv run --locked ruff check .
          uv run --locked pytest -q
      - name: Build Linux ARM64 release ZIP
        run: uv run --locked python build.py
      - name: Check Terraform
        run: |
          terraform fmt -check -recursive
          terraform init -backend=false -input=false -lockfile=readonly
          terraform validate
```

Open the GitHub **Actions** tab to see the run. A green `verify` proves that tests, formatting, packaging, and Terraform validation work on the runner. Keep the OpenAI and AWS credentials in their existing locations. The CI tests use offline fixtures and mocks.

## 3. Prepare shared Terraform state

This is a one-time change for CD. The state maps Terraform addresses to the existing AWS resources. Migrate that state so the runner updates the existing runtime. Coordinate one writer during migration and retain the local backup until the migration is checked. [Terraform backend migration](https://developer.hashicorp.com/terraform/cli/commands/init#backend-initialization) · [S3 backend and state locking](https://developer.hashicorp.com/terraform/language/backend/s3)

1. In the approved AWS project, create a separate private S3 bucket for state in Ohio. Choose a globally unique name such as `incident-triage-tfstate-ACCOUNT-us-east-2`. Turn on **Block all public access**, **Versioning**, and default encryption. Manage the bucket separately so the app's release lifecycle does not remove state storage.
2. From the existing checkout, set `AWS_PROFILE=agentcore-test` in your shell and check the project with STS. Before editing the backend, record the existing managed addresses and back up the local state. Keep its contents out of logs, Git, and workflow artifacts.

```powershell
$env:AWS_PROFILE = 'agentcore-test'
$env:AWS_REGION = 'us-east-2'
aws sts get-caller-identity --profile agentcore-test --region us-east-2 --query Account --output text
terraform state list
Copy-Item -LiteralPath 'terraform.tfstate' -Destination '.tools/terraform.pre-migration.tfstate'
```

3. Add `backend.tf` with this configuration. Supply the bucket name during initialization.

```hcl
terraform {
  backend "s3" {
    key          = "incident-triage-demo/terraform.tfstate"
    region       = "us-east-2"
    profile      = "agentcore-test"
    encrypt      = true
    use_lockfile = true
  }
}
```

```powershell
$stateBucket = 'REPLACE_WITH_YOUR_STATE_BUCKET'
terraform init -migrate-state -backend-config "bucket=$stateBucket"
terraform state list

uv run --locked python build.py
terraform plan -input=false
```

Compare state addresses before and after. Expect the original bucket, public-access block, release ZIP, IAM role and policy, and AgentCore runtime. The new local SDK package can produce an expected ZIP replacement and runtime update. Stop if Terraform wants to create a second runtime or replace the IAM role. A plan showing all the app resources as new usually means the state bucket or key is wrong. Use `-migrate-state` for the one-time copy and plain `init` afterwards.

The old AWS CLI binary on this machine may lack support for the existing console login profile. Terraform has already used that profile successfully. For STS verification use a current compatible CLI with explicit `--profile agentcore-test --region us-east-2`, or use the existing Boto3 console login setup described in [flow.md](flow.md).

## 4. Let GitHub assume a deployment role

1. Create or reuse the IAM OIDC provider `https://token.actions.githubusercontent.com` with audience `sts.amazonaws.com`. Create a separate IAM role such as `incident-triage-github-release`. Keep it independent of the runtime's execution role.
2. Trust the exact repository's `main` branch. For repositories created after July 15, 2026, GitHub uses an immutable default subject containing owner and repository IDs. Use the actual subject for the repo. The example below shows the immutable form for a new repo. Older repos may use `repo:OWNER/REPO:ref:refs/heads/main`. The workflow below uses a branch-based subject. Adding a GitHub environment changes the subject, so adjust the trust and branch protections together if adding one later. [GitHub OIDC with AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws) · [GitHub subject claim formats](https://docs.github.com/en/actions/reference/security/oidc)

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::ACCOUNT:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:refs/heads/main"
      }
    }
  }]
}
```

3. Give the role the permissions below. Fill in the exact resource names from Terraform state and AWS. Use the plan-only run to verify the provider's read calls. If a read is denied, use its action and resource from the error or CloudTrail to add the exact permission. Keep role and bucket administration as a separately reviewed change. [Terraform AWS security guidance](https://docs.aws.amazon.com/prescriptive-guidance/latest/terraform-aws-provider-best-practices/security.html) · [AgentCore action and resource table](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonbedrockagentcore.html)

| Purpose | Permissions and scope |
| --- | --- |
| State and lock | `s3:ListBucket` for the state bucket and state path. `s3:GetObject` and `s3:PutObject` for `incident-triage-demo/terraform.tfstate`. Add `s3:DeleteObject` only for the `.tflock` object, with its own read and write permissions. |
| Deployment ZIP | Bucket configuration reads and listing on the app's existing artifact bucket. `s3:GetObject`, `s3:PutObject`, and `s3:DeleteObject` on `releases/*` in that bucket. The app's Terraform replaces the prior ZIP after update. |
| AgentCore | Read the runtime, endpoints, versions, and tags used by refresh. Allow `bedrock-agentcore:UpdateAgentRuntime` on the exact runtime. Allow `bedrock-agentcore:InvokeAgentRuntime` on the runtime and its `DEFAULT` endpoint resources for smoke tests. |
| Execution role | IAM reads for the current execution role and its inline policy. Scope `iam:PassRole` to `incident-triage-demo-runtime` and restrict it to AgentCore with `iam:PassedToService` equal to `bedrock-agentcore.amazonaws.com`. Keep IAM write access out of the release role. |
| Secret metadata | `secretsmanager:DescribeSecret` on the ARN of `incident-triage-demo/openai`. The runtime execution role holds `secretsmanager:GetSecretValue` for model calls. |

4. Under GitHub **Settings → Secrets and variables → Actions → Variables**, set these repository variables.

| Name | Value |
| --- | --- |
| `AWS_ACCOUNT_ID` | Approved project account ID |
| `AWS_DEPLOY_ROLE_ARN` | ARN of the GitHub OIDC deployer role |
| `TF_STATE_BUCKET` | Name of the migrated state bucket |

The GitHub credentials action creates a temporary named profile on the hosted runner. This keeps `agentcore-test` working with the current Terraform provider, the backend, and `smoke.py`. The existing laptop profile stays usable as the local path. [AWS credentials action and named profiles](https://github.com/aws-actions/configure-aws-credentials#use-named-profiles)

## 5. Add the manual release workflow

After migrating the state and setting up OIDC, save this as `.github/workflows/release.yml`. It runs CI, checks the AWS project, builds the ZIP, and shows a plan. The plan guard allows an update to the existing runtime and replacement of its release ZIP. Deployer IAM gives GitHub only the AWS access it needs for that release path.

```yaml
name: Release agent to AWS

on:
  workflow_dispatch:
    inputs:
      deploy:
        description: Apply the checked plan and run the live smoke cases
        type: boolean
        default: false

permissions:
  contents: read

concurrency:
  group: incident-triage-demo-us-east-2
  cancel-in-progress: false

jobs:
  verify:
    uses: ./.github/workflows/ci.yml

  release:
    needs: verify
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions:
      contents: read
      id-token: write
    env:
      TF_IN_AUTOMATION: "true"
      TF_STATE_BUCKET: ${{ vars.TF_STATE_BUCKET }}
      AWS_ACCOUNT_ID: ${{ vars.AWS_ACCOUNT_ID }}
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - uses: astral-sh/setup-uv@68559e99cc807c1eb7e9238fd43a15bba460eec2 # v10.3.3
        with:
          version: "0.10.0"
      - uses: hashicorp/setup-terraform@v4
        with:
          terraform_version: "1.14.5"
          terraform_wrapper: false
      - name: Build release
        run: |
          uv sync --locked
          uv run --locked python build.py
      - name: Get temporary AWS credentials
        uses: aws-actions/configure-aws-credentials@v6.3.0
        with:
          aws-region: us-east-2
          role-to-assume: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
          aws-profile: agentcore-test
          allowed-account-ids: ${{ vars.AWS_ACCOUNT_ID }}
      - name: Preview changes
        run: |
          test -n "$TF_STATE_BUCKET"
          test -n "$AWS_ACCOUNT_ID"
          account="$(aws sts get-caller-identity --profile agentcore-test --region us-east-2 --query Account --output text)"
          test "$account" = "$AWS_ACCOUNT_ID"
          terraform init -input=false -lockfile=readonly -backend-config="bucket=$TF_STATE_BUCKET"
          terraform plan -input=false -no-color -lock-timeout=2m -out="$RUNNER_TEMP/release.tfplan"
      - name: Check the release plan
        run: |
          terraform show -json "$RUNNER_TEMP/release.tfplan" | python -c '
          import json, sys
          allowed = {
              "aws_bedrockagentcore_agent_runtime.triage": ("update",),
              "aws_s3_object.agent": ("create", "delete"),
          }
          for item in json.load(sys.stdin).get("resource_changes", []):
              if item["mode"] != "managed":
                  continue
              actions = tuple(item["change"]["actions"])
              if actions == ("no-op",):
                  continue
              print(item["address"], ", ".join(actions))
              if allowed.get(item["address"]) != actions:
                  sys.exit("Unexpected release action. Review Terraform separately.")
          '
      - name: Apply the checked plan
        if: inputs.deploy
        run: terraform apply -input=false -no-color -lock-timeout=2m "$RUNNER_TEMP/release.tfplan"
      - name: Run both live smoke cases
        if: inputs.deploy
        run: |
          runtime_arn="$(terraform output -raw runtime_arn)"
          runtime_id="${runtime_arn##*/}"
          version="$(aws bedrock-agentcore-control get-agent-runtime \
            --agent-runtime-id "$runtime_id" --profile agentcore-test --region us-east-2 \
            --query agentRuntimeVersion --output text)"
          ready=false
          for attempt in {1..12}; do
            endpoint="$(aws bedrock-agentcore-control get-agent-runtime-endpoint \
              --agent-runtime-id "$runtime_id" --endpoint-name DEFAULT \
              --profile agentcore-test --region us-east-2 --query '[status,liveVersion]' --output text)"
            read -r status live_version <<< "$endpoint"
            if [[ "$status" == READY && "$live_version" == "$version" ]]; then
              ready=true
              break
            fi
            sleep 5
          done
          test "$ready" = true
          echo "Testing DEFAULT version $version"
          uv run --locked python smoke.py --runtime-arn "$runtime_arn"
```

A plan stays in the temporary runner directory. The apply step uses the saved plan and ZIP from the same job. The next manual run creates a fresh plan from the then-current state, so review the selected branch and commit before enabling `deploy`. For stricter review of the exact plan before apply, add a protected deployment environment with a reviewer when the repository plan supports it, and design secure transfer of the saved plan and matching ZIP. [Manual workflow runs](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow) · [Terraform plan and apply](https://developer.hashicorp.com/terraform/cli/commands/plan)

## 6. Verify the first release and recover a failed one

1. Run **Actions → Release agent to AWS → Run workflow** on `main` with `deploy` off. Verify the correct AWS project, state, and expected limited changes. Resolve any permissions or unexpected plan changes here.
2. Run it again for the intended commit with `deploy` on. Check that Terraform updates the same runtime ARN. The job waits for `DEFAULT` to serve the ready version before running the smoke tests. Look for `incident: ok` and `tool_failure: evidence_unavailable`.
3. Check the two request IDs in CloudWatch Logs. Record the Git commit SHA, workflow run, runtime version, and smoke outcomes in `flow.md`. Each successful incident smoke case makes one small OpenAI call.
4. If the release fails, check the job stage and runtime logs before rerunning. A deployment may have succeeded even when a smoke test failed. For an application regression, revert the source change on `main`, build the restored source, review a fresh plan, and release it through the same workflow. The current Terraform releases replace the previous S3 ZIP, so a source rebuild is the repeatable rollback path. Use state backups only for a state problem.

### Handoff checklist

- [ ] Commit the repo and get a green credential-free CI run.
- [ ] Create and verify the separate private state bucket, then migrate the existing state.
- [ ] Set up the named-profile GitHub OIDC role and repository variables.
- [ ] Get a green plan-only run that points to the existing runtime.
- [ ] Run the approved release and record both smoke outcomes.
