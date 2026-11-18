# Incident triage agent flow

> Historical build journal from the original deployment. It documents observed versions and account-local steps; use README.md and CICD.md to deploy a separate copy. Do not reuse the original AWS profile, state, or runtime identifiers.

We built a small agent locally for Amazon Bedrock AgentCore. It answers “Why is checkout returning 503s?” from two sample log events. The same example lets us show a normal result and a tool failure during a release check.

## 1. Write the triage logic

In `triage.py`, Python reads the sample events and passes them to a function that writes the summary. The result includes the event IDs so you can check the evidence. The `tool_failure` scenario returns `evidence_unavailable` and skips the model call. The sample data makes both outcomes easy to replay.

We chose a standalone Python workflow because this demo always runs one known tool. Strands would be a small next step if the model needed to choose among tools. The entry point in `main.py` can keep the same request and response while the logic inside changes. AgentCore Runtime supports different frameworks as long as the app follows its runtime interface. [AWS guide to runtime frameworks](https://aws.amazon.com/blogs/machine-learning/securely-launch-and-scale-your-agents-and-tools-on-amazon-bedrock-agentcore-runtime/) · [Strands Python quickstart](https://strandsagents.com/docs/user-guide/quickstart/python)

## 2. Run and test it on the laptop

The AgentCore Python SDK gives `main.py` an HTTP entry point. Offline mode listens on localhost and uses a fixed answer, so the tests can run without credentials or model charges. The first cloud deployment used Bedrock Converse. Step 8 records the switch to OpenAI. [AgentCore Python deployment guide](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-get-started-code-deploy-python.html)

In PowerShell from the project folder:

```powershell
uv sync --locked
uv run --locked ruff format --check .
uv run --locked ruff check .
uv run --locked pytest -q
$env:TRIAGE_OFFLINE = '1'
uv run --locked python main.py
```

While the server is running, open a second terminal in the same folder and run:

```powershell
uv run --locked python smoke.py
```

The smoke check sends two HTTP requests. It expects `ok` with `evt-001` and `evt-002` for the incident, and `evidence_unavailable` with an empty list for the failure. Six Python tests, both Ruff checks, and both local HTTP cases passed.

## 3. Build the file AWS will run

`uv run --locked python build.py` builds `dist/agent.zip`. It packages Python 3.13 dependencies for Linux ARM64, even on Windows. The build adds a Linux launcher for OpenTelemetry because a Windows launcher cannot run inside AgentCore. The tool and model call have separate trace steps so you can see where work happened and where it failed. [AWS ZIP packaging guide](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-get-started-code-deploy-python.html) · [AgentCore tracing setup](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-configure.html)

## 4. Check the Terraform locally

`main.tf` describes a private S3 bucket for the ZIP, a limited IAM role, and an AgentCore Runtime. The ZIP's name includes its content hash so new code is picked up as a new version. Terraform formatting and validation passed with the locked AWS provider. [Terraform Runtime resource](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrockagentcore_agent_runtime) · [Runtime versions](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agent-runtime-versioning.html)

```powershell
terraform fmt -check
terraform init -backend=false
terraform validate
```

On this machine, Terraform 1.14.5 is in `.tools/terraform-1.14.5/terraform.exe`. If `terraform` is unavailable in your terminal, run the same commands with that executable.

## 5. Check the AWS project and preview the first Bedrock deployment

On November 18, 2026, we used the original local AWS profile in `us-east-2`. STS confirmed the project role, and the Free Tier API reported an active Free plan. AWS reported `amazon.nova-lite-v1:0` as available and authorized in Ohio, and it appeared in the on-demand text model list. These checks help confirm the target before changing anything. [Free-plan services](https://docs.aws.amazon.com/accounts/latest/reference/supported-services-sign-up-new.html) · [Model availability API](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_GetFoundationModelAvailability.html)

The profile uses console sign-in credentials. Our local checks used `uv run --locked --with 'boto3[crt]==1.44.5'` to add the sign-in support in a temporary Python environment. The deployed agent uses its own IAM role. [Boto3 sign-in setup](https://docs.aws.amazon.com/boto3/latest/guide/credentials.html#login-with-console-credentials)

We saved the Terraform preview and verified six creates: the bucket, its public-access block, the ZIP object, the execution role, its permissions policy, and the AgentCore Runtime. Then we applied the saved plan so Terraform would make the changes we had reviewed. [Terraform plan](https://developer.hashicorp.com/terraform/cli/commands/plan)

```powershell
terraform plan -input=false -var 'model_id=amazon.nova-lite-v1:0' -out .tools/incident-triage.tfplan
terraform apply -input=false .tools/incident-triage.tfplan
```

## 6. Deploy the Bedrock version and run the live smoke cases

Terraform created all six resources on the Free plan. AgentCore reported that the `DEFAULT` endpoint was ready on version 1. The first apply was stopped by the approval review, which had used the earlier cleanup instruction. The same saved plan ran after the newer deployment instruction was provided to the review.

The smoke script sends test requests to AgentCore. On the normal path, the runtime reads the sample logs and uses Boto3 to call Nova Lite through Bedrock `Converse`. The simulated tool-failure path returns `evidence_unavailable` before it reaches the model. [AgentCore invocation](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-invoke-agent.html) · [Bedrock Converse](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_Converse.html)

```powershell
$runtimeArn = terraform output -raw runtime_arn
uv run --locked --with 'boto3[crt]==1.44.5' python smoke.py --runtime-arn $runtimeArn
```

| Live case | Observed result |
| --- | --- |
| Checkout incident | The request reached Bedrock, which returned `ThrottlingException` for the daily token limit. AgentCore returned HTTP 500. Service Quotas showed an applied Nova Lite daily token quota of zero. |
| Simulated tool failure | Passed in a separate live request after the first case stopped the script. The result was `evidence_unavailable` with no evidence IDs. |

Model availability is a check that a model exists and can be selected. The applied quota controls whether the model can accept a request. [Bedrock runtime quotas](https://docs.aws.amazon.com/bedrock/latest/userguide/quotas-runtime.html)

We looked for an in-region fallback. All 90 model-specific on-demand quotas returned by Service Quotas were zero. That included the requests-per-minute and tokens-per-minute quotas for Ministral 3B, GPT OSS 20B, and Gemma 3 4B. At that point, the deployment still used Nova Lite on the active Free plan.

We rechecked the cause with read-only AWS calls. Nova Lite's daily quota (`L-45E0AD92`) returned **0 applied tokens** for the project and an AWS default of **5,760,000,000**. AWS marked the quota as non-adjustable. The IAM simulator allowed `bedrock:InvokeModel` for the deployed execution role on the Ohio Nova Lite model and reported that Organizations allowed it in the simulation. The model availability check returned authorized, available in Ohio, and entitled. The live CloudWatch error was a daily-token-limit `ThrottlingException`. Together these checks point to the applied quota as the blocker for the tested request. [Bedrock service quotas](https://docs.aws.amazon.com/general/latest/gr/bedrock.html#limits_bedrock) · [IAM simulator](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_testing-policies.html)

## 7. Read CloudWatch logs and look for traces

AgentCore created the `/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT` CloudWatch log group. Its logs showed the Bedrock quota error and an OpenTelemetry span export error. Searching for the tool-failure request ID returned two records, including the `evidence_unavailable` status. The runtime's `spans` stream returned zero events during the check.

Logs record what the runtime reported. A trace links steps, such as the log lookup and model call, to one request. This project's Ohio trace destination was still X-Ray, and the approval review blocked switching it to CloudWatch Transaction Search because that changes routing for the whole project in the Region and adds a log-write policy. The AWS setting stayed as it was. [AgentCore observability](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-view.html) · [Transaction Search setup](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Enable-TransactionSearch.html)

## 8. Switch the model to GPT-6 Luna

The agent still reads the two sample checkout events and sends a short prompt for a summary. The model call now uses OpenAI's Responses API with `gpt-6-luna` and `reasoning.effort` set to `medium`. We allow one model request with a limit of 1,024 tokens for reasoning and output. The simulated tool failure returns before the agent reads the key or calls OpenAI. [GPT-6 Luna](https://developers.openai.com/api/docs/models/gpt-6-luna) · [Reasoning settings](https://developers.openai.com/api/docs/guides/reasoning)

We used the key from the local `.env` file to run the two cases through the local AgentCore HTTP route. The checkout case returned `ok` with both evidence IDs. The simulated tool failure returned `evidence_unavailable`. Eight Python tests, Ruff, and Terraform validation also passed.

To replay the live local test, start the server from the project folder in PowerShell. The key comes from `OPENAI_API_KEY` in the ignored `.env` file.

```powershell
$env:TRIAGE_OFFLINE = '0'
uv run --locked --env-file .env python main.py
```

In a second terminal in the project folder:

```powershell
uv run --locked python smoke.py --local-live
```

### Store the key for AWS

1. Open **AWS Secrets Manager** in **US East (Ohio)**.
2. Choose **Store a new secret**, then **Other type of secret**.
3. Pick **Key/value** and set the field name to `OPENAI_API_KEY`. Enter your key directly in the value field.
4. Keep the default encryption key `aws/secretsmanager` and name the secret `incident-triage-demo/openai`.
5. Leave automatic rotation off for this demo, review the details, and choose **Store**.

Terraform reads the secret's ARN. The runtime role can use that ARN to read the value when it first needs to call OpenAI. [Create a secret](https://docs.aws.amazon.com/secretsmanager/latest/userguide/create_secret.html) · [Terraform secret metadata](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/secretsmanager_secret)

After the local test passed, we created that secret in Ohio from the key in `.env` using the AWS SDK and the original local AWS profile. AWS confirmed the Free plan was active. The ZIP inspection confirmed the application and OpenAI SDK were included and the local `.env` file was excluded.

### Update the existing AgentCore Runtime

We previewed an in-place update to the runtime and its role policy, plus replacement of the old code ZIP. The policy grants `secretsmanager:GetSecretValue` on the one secret. The runtime gets the secret ARN as configuration and reads the key when handling a request. [Secrets Manager permissions](https://docs.aws.amazon.com/secretsmanager/latest/userguide/auth-and-access_iam-policies.html) · [AgentCore Runtime versions](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agent-runtime-versioning.html)

```powershell
uv run --locked python build.py
terraform plan -input=false -out .tools/incident-triage-openai.tfplan
terraform apply -input=false .tools/incident-triage-openai.tfplan
```

### Verify version 2 on AWS

Terraform updated the existing `incident_triage_demo` runtime. AWS confirmed `DEFAULT` was **READY** on version **2**. We ran the same two smoke cases against that version with the the original local AWS profile in Ohio.

```powershell
$runtimeArn = terraform output -raw runtime_arn
uv run --locked --with 'boto3[crt]==1.44.5' python smoke.py --runtime-arn $runtimeArn
```

| Live case | Result | Request ID |
| --- | --- | --- |
| Checkout incident | `ok`, evidence IDs `evt-001` and `evt-002` | `667b881154fb46b5956f50a0e386c601` |
| Simulated tool failure | `evidence_unavailable`, empty evidence list | `8c008da025fa477695983e013359de8a` |

CloudWatch Logs recorded both request IDs and `model=gpt-6-luna effort=medium`. Look in `/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT`. The span stream returned zero events and the trace destination was still X-Ray. [AgentCore logs and traces](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-view.html)

### Try the agent in the console

Open AgentCore in **US East (Ohio)**. Choose **Agents → incident_triage_demo → Endpoints → DEFAULT → Test endpoint**. Run the first JSON payload for the normal case and the second for the simulated failure. [AgentCore console](https://console.aws.amazon.com/bedrock-agentcore/home?region=us-east-2) · [AWS console test walkthrough](https://aws.amazon.com/blogs/machine-learning/build-ai-powered-dashboard-automation-agents-with-nlp-on-amazon-bedrock-agentcore/)

```json
{"question":"Why is checkout returning 503s?"}
```

```json
{"question":"Why is checkout returning 503s?","scenario":"tool_failure"}
```

The source code is in `main.py` and `triage.py` in this repo. Terraform uploads the ZIP to S3. AgentCore unpacks it into its managed runtime and runs `main.py` when you call the endpoint. S3 holds the ZIP. [AWS direct code deployment](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-get-started-code-deploy-python.html)

| AgentCore capability | What this demo proves |
| --- | --- |
| Runtime | The hosted Python code answered both requests on version 2. |
| Gateway | Separate test needed. Expose a tool through Gateway and call it. |
| Memory | Separate test needed. Write and retrieve an item through AgentCore Memory. |
| Identity | AWS records a workload identity for the runtime. The live call proves the IAM role could read the secret. A credential-provider or user-delegation flow needs its own test. |
| Observability | CloudWatch Logs confirmed both outcomes and the model setting. Full trace verification needs Transaction Search. |

The **Enable** button in the Observability overview applies to Insights. The two live smoke cases can be reproduced from the agent's endpoint.

## 9. Use the OpenAI Agents SDK

The local agent now uses the OpenAI Agents SDK's async runner for the summary, using one turn of GPT-6 Luna at medium reasoning. The Python workflow retrieves the evidence first, so a failed lookup still returns before a model call. The request and response match the console examples above. [AWS AgentCore framework example](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/using-any-agent-framework.html)

Eight unit tests, the two offline HTTP cases, and both live local cases passed. The Linux ARM64 ZIP includes the SDK. Step 11 records the AWS release and its verification. The [CI/CD handoff](setup%20terraform%20cicid.md) covers setting up repeatable releases with GitHub Actions.

## 10. Recheck the AWS demo after trace routing became active

On November 18, 2026, the Ohio `DEFAULT` endpoint was ready on version 2 and AWS reported `CloudWatchLogs` as the active trace destination. Both live smoke cases passed again. CloudWatch correlated each request ID with its trace.

| Case | Request ID | What the trace showed |
| --- | --- | --- |
| Checkout incident | `01b8b66632f044c2be8304934143931a` | The log lookup, Secrets Manager read, and OpenAI Responses call. |
| Simulated tool failure | `8f0d384bc5964fc4b5c5c634ffa5a9b1` | The request reached the log lookup and ended there. |

For a quick demo, use **AgentCore → Agents → incident_triage_demo → DEFAULT → Test endpoint** in Ohio. Try the two JSON payloads above and show the traces for the successful request and the controlled failure. Version 2 proved the flow before the SDK release in step 11.

## 11. Deploy and verify the OpenAI Agents SDK release

The 40.9 MiB Linux ZIP passed its integrity check, contains the Agents SDK, and matches the current `main.py` and `triage.py`. Terraform validation also passed. Local Terraform state points to the existing `incident_triage_demo` runtime in Ohio.

The automatic approval review initially rejected the preview under the earlier cleanup-only instruction. After the user superseded that instruction for this release, we verified that the saved plan contained an in-place runtime update and a replacement of the ZIP. Terraform applied it on November 18, 2026, with the the original local AWS profile in `us-east-2`. The existing `DEFAULT` endpoint reported **READY**, version **3**, and AWS referenced the verified SDK ZIP.

```powershell
terraform plan -input=false -out .tools/incident-triage-sdk.tfplan
terraform apply -input=false .tools/incident-triage-sdk.tfplan
$runtimeArn = terraform output -raw runtime_arn
uv run --locked --with 'boto3[crt]==1.44.5' python smoke.py --runtime-arn $runtimeArn
```

| Live case | Result | CloudWatch trace | Request ID |
| --- | --- | --- | --- |
| Checkout incident | `ok`, evidence IDs `evt-001` and `evt-002` | The log lookup, Secrets Manager read, and OpenAI Responses call. The model span recorded `gpt-6-luna` and `medium`. | `cfdf136b202749f397ce4075e47dac7f` |
| Simulated tool failure | `evidence_unavailable`, empty evidence list | The log lookup span recorded `ERROR` for the simulated failure. The trace ended before model inference. | `0c7da6c3123e43749da11a5bbcfe6d54` |

Both smoke cases passed on version 3. CloudWatch trace routing was active, and the request IDs matched logs and spans in `/aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT`. [AgentCore logs and traces](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-view.html)

**Demo version 3 in Ohio.** Open [AgentCore](https://console.aws.amazon.com/bedrock-agentcore/home?region=us-east-2), choose **Agents → incident_triage_demo → DEFAULT → Test endpoint**, and use the JSON payloads in [Try the agent in the console](#try-the-agent-in-the-console). In the traces, show where the successful request reaches OpenAI and where the simulated failure stops.
