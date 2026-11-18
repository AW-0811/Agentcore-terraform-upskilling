# Incident triage on Amazon Bedrock AgentCore

This is a hands-on project to learn Amazon Bedrock AgentCore Runtime and Terraform. I kept the agent small so I could focus on deploying it, following a request in CloudWatch, and testing what happens when a dependency fails.

The demo looks up sample checkout logs and makes one model call to summarize the evidence. It returns a short summary with the evidence IDs. A second scenario simulates an unavailable log source.

## What I learned and tested

- **Deployment.** I packaged the Python app for Linux ARM64 and used Terraform to deploy it to AgentCore Runtime. The agent uses the OpenAI Responses API, with its API key stored in AWS Secrets Manager.
- **Observability.** I used OpenTelemetry traces to follow the evidence lookup and model call. The CloudWatch dashboard shows runtime metrics such as invocation counts, errors, and latency.
- **Release checks.** After deploying to AWS with Terraform, I ran both smoke checks against the live runtime. The normal request returned `ok` with evidence IDs `evt-001` and `evt-002`. The simulated failure returned `evidence_unavailable` with an empty evidence list. I configured the AWS release pipeline to run these checks after an approved Terraform apply.

## Try the demo locally

Install [uv](https://docs.astral.sh/uv/getting-started/installation/). It can install Python 3.13 for you. From the repository root, start the offline demo in PowerShell:

```powershell
uv sync --locked
$env:TRIAGE_OFFLINE = '1'
uv run --locked python main.py
```

In a second PowerShell terminal opened at the repository root, run:

```powershell
uv run --locked python smoke.py
```

Expect `incident: ok` and `tool_failure: evidence_unavailable`, each with a request ID. Offline mode uses a fixed summary and needs no AWS credentials or OpenAI API key. To run the unit tests, use `uv run --locked pytest -q`.

## What the AWS setup needs

- An AWS account with deployment permissions for AgentCore, IAM, S3, Secrets Manager, and CloudWatch. The Terraform configuration targets `us-east-2`.
- Terraform 1.14.5, Python 3.13, `uv`, and a private S3 bucket for Terraform state.
- An OpenAI API key with access to `gpt-6-luna`, stored in Secrets Manager as `incident-triage-demo/openai`.
- CloudWatch Transaction Search enabled to view traces.
- For the optional release pipeline, CodePipeline and CodeBuild permissions and a GitHub repository authorized through AWS CodeConnections.

The runtime is defined in `main.tf`, the dashboard and alarms in `observability.tf`, and the release pipeline in `cicd/`.

A fresh AWS deployment needs the runtime to exist before Terraform can import its CloudWatch log group.
