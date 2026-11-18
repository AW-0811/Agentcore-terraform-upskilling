# Incident triage agent

This demo answers one question: “Why is checkout returning 503s?” It looks up two sample log events, then asks GPT‑6 Luna to summarize the evidence and suggest what to check next. If the lookup fails, it reports that the evidence is unavailable and skips the model call.

The app is Python 3.13 and uses the OpenAI Agents SDK with medium reasoning. Amazon Bedrock AgentCore Runtime runs the Python code on AWS, OpenAI provides the model, and CloudWatch shows what happened in each request. Terraform manages the AWS resources that host the app. The last verified AWS release was version **3** on the `DEFAULT` endpoint in **US East (Ohio)**. [AgentCore deployment guide](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-get-started-code-deploy-python.html) · [Release and trace evidence](flow.md#11-deploy-and-verify-the-openai-agents-sdk-release)

## What is in this folder?

| File | What it does |
| --- | --- |
| [main.py](main.py) | Receives requests, loads the model key when needed, runs the Agents SDK, and records trace steps. |
| [triage.py](triage.py) | Defines the incident logic and sample events. Handles a failed evidence lookup. |
| [test_triage.py](test_triage.py), [smoke.py](smoke.py) | Run unit tests and send the two demo requests to the local or AWS endpoint. |
| [build.py](build.py) | Packages the Python app and its dependencies as `dist/agent.zip` for Linux ARM64. |
| [main.tf](main.tf) | Sets up the private S3 bucket and ZIP object, the runtime's IAM role and permissions, and AgentCore Runtime. |
| [observability.tf](observability.tf), [OBSERVABILITY.md](OBSERVABILITY.md) | Configures the CloudWatch dashboard, error alarms, and 30-day runtime log retention. |
| [bootstrap/](bootstrap/), [cicd/](cicd/), [CICD.md](CICD.md) | Set up protected remote Terraform state and GitHub-to-AWS delivery through CodePipeline and CodeBuild. |
| [pyproject.toml](pyproject.toml), [uv.lock](uv.lock), [.python-version](.python-version) | Define and pin the Python environment. |
| [.terraform-version](.terraform-version), [.terraform.lock.hcl](.terraform.lock.hcl) | Pin Terraform and its AWS provider. |
| [.env.example](.env.example) | Shows the variable name to use in an ignored `.env` file for a local live model test. |
| [flow.md](flow.md) | Explains how the project was built, deployed, and verified. Includes console test inputs and CloudWatch evidence. |
| [THINGS_TO_EXPLORE.md](THINGS_TO_EXPLORE.md), [setup terraform cicid.md](<setup terraform cicid.md>) | Cover multi-agent experiments and the historical CI/CD design notes. |

## Run it on your laptop

Install uv and run these PowerShell commands from the project folder. The offline demo uses a fixed summary and needs only the local Python environment. [Install uv](https://docs.astral.sh/uv/getting-started/installation/)

```powershell
uv sync --locked
uv run --locked pytest -q
$env:TRIAGE_OFFLINE = '1'
uv run --locked python main.py
```

With the server running, open a second terminal in the same folder.

```powershell
uv run --locked python smoke.py
```

The normal request should return `ok` with `evt-001` and `evt-002`. The simulated failure should return `evidence_unavailable` with an empty evidence list.

For a real OpenAI call on your laptop, put your key in the ignored `.env` as `OPENAI_API_KEY`. Stop the offline server, then start it with `$env:TRIAGE_OFFLINE = '0'` and `uv run --locked --env-file .env python main.py`. Run `uv run --locked python smoke.py --local-live` in the second terminal. This uses your OpenAI API account.

## Use it on AWS

- To **try the existing demo**, open AgentCore in Ohio, select **Agents → incident_triage_demo → Endpoints → DEFAULT → Test endpoint**, then paste the normal and failure payloads. Open Observability and look for the traces from those requests. [AWS console](https://console.aws.amazon.com/bedrock-agentcore/home?region=us-east-2) · [Demo payloads](flow.md#try-the-agent-in-the-console) · [CloudWatch evidence](flow.md#11-deploy-and-verify-the-openai-agents-sdk-release)
- To **deploy an update**, use Terraform 1.14.5, working AWS credentials in the `agentcore-test` profile for Ohio, and the Terraform state that already owns the deployment. AWS Secrets Manager in Ohio needs a secret named `incident-triage-demo/openai` with the key field `OPENAI_API_KEY`. The runtime reads it through its IAM role. Build the ZIP with `uv run --locked python build.py`, review the Terraform plan, then apply and run the two AWS smoke cases. [Secret setup](flow.md#store-the-key-for-aws) · [Release commands](flow.md#11-deploy-and-verify-the-openai-agents-sdk-release)

For a fresh AWS setup, create the secret first, build the ZIP, and run `terraform init` with the pinned version before planning. The first plan is expected to create the S3, IAM, and Runtime resources. For an existing deployment, locate its Terraform state before planning an update.

GitHub Actions runs CI checks. AWS CodePipeline and CodeBuild handle deployment through a manual approval step. The Terraform setup is documented in [CICD.md](CICD.md); first create the protected remote-state bucket, migrate the existing state, then connect the private GitHub repository in AWS Console. The older [CI/CD handoff notes](<setup terraform cicid.md>) are historical and include an OIDC approach that this AWS project blocks.
