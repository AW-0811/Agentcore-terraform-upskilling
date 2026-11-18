# Incident triage agent on Amazon Bedrock AgentCore

A small, reproducible serverless agent demo. Give it an incident question; it looks up sample log evidence, asks an OpenAI model to summarize what the evidence suggests, and returns the summary with evidence IDs. A built-in failure scenario shows how the app responds when evidence is unavailable.

The repository includes the agent, OpenTelemetry instrumentation, CloudWatch observability resources, Terraform infrastructure, GitHub CI, and an AWS deployment pipeline. The public setup below is for creating **your own isolated copy**. The existing demo is already deployed in the original owner's AWS project; you do not need that AWS project to try the local demo.

## Architecture at a glance

```text
User request
  -> Amazon Bedrock AgentCore Runtime
      -> sample evidence lookup
      -> OpenAI Responses API (credential from AWS Secrets Manager)
  -> response with status, summary, evidence IDs, and request ID

GitHub push -> GitHub Actions CI
            -> AWS CodePipeline / CodeBuild
            -> checks + Linux ARM64 ZIP + Terraform plan
            -> manual plan approval -> Terraform apply -> live smoke checks

AgentCore logs, traces, and metrics -> CloudWatch / AgentCore Observability
Terraform-managed dashboard, alarms, and 30-day runtime log retention
```

## Try it locally first

Prerequisites: Python 3.13 (or let `uv` install it) and [uv](https://docs.astral.sh/uv/getting-started/installation/).

```powershell
uv sync --locked
uv run --locked pytest -q
$env:TRIAGE_OFFLINE = '1'
uv run --locked python main.py
```

In another terminal, from the repository directory:

```powershell
uv run --locked python smoke.py
```

The normal example returns `ok` with evidence IDs `evt-001` and `evt-002`. The failure example returns `evidence_unavailable`. Offline mode uses a fixed summary and needs no AWS credentials or model API key.

To make a real OpenAI call locally, create an OpenAI API key and place it in a local `.env` file (ignored by Git):

```text
OPENAI_API_KEY=your-key
```

Start the server with `$env:TRIAGE_OFFLINE = '0'; uv run --locked --env-file .env python main.py` and, in a second terminal, run `uv run --locked python smoke.py --local-live`. Model API use may incur charges.

## Deploy your own copy to AWS

This creates AWS resources in your selected Region and can incur charges. Review the AWS console billing/spend settings, service availability, and each Terraform plan before applying. The current example is configured for `us-east-2` (US East, Ohio); changing Regions requires updating the provider/backend settings consistently.

Prerequisites:

- An AWS project with access to Amazon Bedrock AgentCore, S3, IAM, Secrets Manager, CloudWatch, CodePipeline, CodeBuild, and CodeConnections in the selected Region.
- AWS CLI v2, Terraform **1.14.5**, Python 3.13, and `uv`.
- An OpenAI API key. It is stored in your own AWS Secrets Manager secret, never committed to Git.
- A GitHub repository for your copy, and authorization of the AWS CodeConnections GitHub App to that repository.

### 1. Authenticate and create your model secret

Sign in using the AWS authentication method configured for your project. Confirm the selected AWS identity and Region before creating resources. Create a Secrets Manager secret containing a JSON object with the key `OPENAI_API_KEY`. The Terraform configuration currently expects the secret name `incident-triage-demo/openai`; change that setting in `main.tf` if you want a different name.

### 2. Build and deploy the application

```powershell
uv sync --locked
uv run --locked pytest -q
uv run --locked python build.py
$env:AWS_PROFILE = 'your-aws-profile'
$env:AWS_DEFAULT_REGION = 'us-east-2'
terraform init -backend-config="bucket=YOUR_EXISTING_STATE_BUCKET"
terraform plan -out=release.tfplan
terraform show release.tfplan
```

For a brand-new project, create and review the protected remote-state bucket using `bootstrap/` first. The detailed bootstrap, state, and deployment steps are in [CICD.md](CICD.md). The S3 backend must be supplied a bucket name at initialization. Keep Terraform state private: it can contain sensitive infrastructure data.

Review the plan carefully before `terraform apply release.tfplan`. A first deployment should create a runtime and supporting resources; an update to an existing deployment should update the intended runtime in place. Do not point a new checkout at someone else's Terraform state or reuse their runtime name and AWS resources.

### 3. Add automated AWS delivery (optional)

GitHub Actions runs code checks, tests, packaging, and Terraform validation. The AWS CodePipeline/CodeBuild Terraform root (`cicd/`) adds the AWS delivery pipeline for a repository you control. It creates an AWS connection, build projects, roles, and pipeline resources; finish the GitHub authorization in the AWS Console after Terraform creates the pending connection. The pipeline builds and tests, creates a Terraform plan, checks it with a resource-action guard, pauses for human approval, then applies the reviewed plan and invokes the live smoke cases.

Follow [CICD.md](CICD.md) for the full sequence. That guide explains how to create and migrate remote state, configure your repository owner/name and runtime outputs, authorize CodeConnections, and review the pipeline plan. The pipeline template currently expects an existing runtime; deploy the app first. Review its plan before applying it, because it creates AWS resources and can incur charges.

## Observability

The agent creates OpenTelemetry spans for the request, evidence lookup, and OpenAI call. The OpenAI span records model name and token usage. AgentCore runtime logs, traces, and service metrics are available through AgentCore Observability and CloudWatch. Terraform configures a CloudWatch dashboard for invocations, errors, throttles, latency, overhead, CPU, and memory; alarms for system errors and throttles; and 30-day retention on the runtime log group. The alarms currently have no email or paging action. See [OBSERVABILITY.md](OBSERVABILITY.md).

## What is in the repository?

| Path | Purpose |
| --- | --- |
| `main.py`, `triage.py` | AgentCore entry point, model call, evidence lookup, response, and OpenTelemetry spans. |
| `test_triage.py`, `smoke.py` | Offline unit tests and local/deployed end-to-end checks. |
| `build.py` | Reproducible Linux ARM64 runtime ZIP builder. |
| `main.tf`, `observability.tf`, `backend.tf` | AgentCore app, IAM/S3 resources, CloudWatch observability, and remote state configuration. |
| `bootstrap/` | Protected, versioned S3 bucket for Terraform remote state. |
| `cicd/`, `.github/workflows/` | AWS CodePipeline/CodeBuild deployment and GitHub Actions CI. |
| `CICD.md`, `OBSERVABILITY.md` | Setup instructions and observability details. |
| `flow.md`, `THINGS_TO_EXPLORE.md` | Project learning notes and follow-on experiments. |

## Known limits

- The evidence source is sample data, not a connection to a real incident or log system.
- The agent is a learning demo, not an autonomous production incident responder.
- CloudWatch alarms show state but do not notify anyone until you configure an alarm action and recipient.
- The deployment pipeline includes a manual approval gate by design.
- The original owner's live deployment and AWS state are separate from a public user's copy.

## Learning notes

This project was built as a hands-on introduction to serverless agents, AWS infrastructure, observability, and CI/CD. [THINGS_TO_EXPLORE.md](THINGS_TO_EXPLORE.md) has follow-on exercises. The detailed [flow.md](flow.md) is a historical build journal and includes owner-specific deployment evidence; use the setup guide above to deploy your own copy.
