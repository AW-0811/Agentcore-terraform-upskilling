# Incident triage observability and delivery plan

## What is running today

- One AgentCore Runtime is live in `us-east-2`: `incident_triage_demo`, runtime ID `incident_triage_demo-pWYrie6l4Z`.
- Its `DEFAULT` endpoint is `READY` on version `3`.
- The runtime already uses AWS Distro for OpenTelemetry (ADOT) instrumentation and emits service metrics. CloudWatch Transaction Search is active and sends trace segments to CloudWatch Logs.
- Before this observability change, the runtime log group had no retention limit and there were no project-owned CloudWatch dashboards or metric alarms.
- Terraform currently tracks the runtime, its execution role and inline policy, the private S3 artifact bucket and access block, and the uploaded agent ZIP. Its state is local in `terraform.tfstate`.

## First observability layer

`observability.tf` adds:

- A CloudWatch dashboard for invocation volume, system and user errors, throttles, p95 latency, runtime overhead, and CPU/memory usage.
- Metric alarms for runtime system errors and throttles. Missing data is treated as non-breaching, which avoids alerts when the demo is idle.
- Terraform management of the existing AgentCore log group with 30-day retention. An import block adopts the existing group, and `prevent_destroy` protects it from accidental Terraform deletion.

The alarms have no notification actions yet. They show state on the dashboard; email or another notification path needs an SNS topic and a confirmed recipient. The dashboard and alarms may add CloudWatch charges. Runtime resource-use telemetry may arrive up to 60 minutes late, so it is for trend and cost context rather than immediate alerting.

The dashboard uses AgentCore's service metrics only. It does not add request or model payloads to dashboard widgets. The application already records its own trace attributes and request status.

## Verification so far

- Terraform applied the observability changes: one existing log group imported and updated, one dashboard created, and two alarms created. The AgentCore runtime was not changed.
- `uv sync --locked` succeeded, and `uv run --locked pytest -q` passed all 8 tests. The only output was a dependency deprecation warning from the AgentCore SDK's Pydantic model.
- Both live smoke cases passed: `incident: ok` (request `4182afd08fad4193838774d611b87c7b`) and `tool_failure: evidence_unavailable` (request `e32e215a3be34af3aa6b30b14272b165`). Their request IDs appeared in CloudWatch runtime logs and spans.
- Both CloudWatch alarms are now `OK`. They have no notification actions configured.

## CI/CD decision and current limitation

The repository handoff describes GitHub Actions for credential-free CI and GitHub OIDC for AWS deployment. AWS returned an explicit service-control-policy deny for IAM OIDC provider actions (`iam:*Provider*`). That prevents GitHub Actions from federating directly into this project. We can still run GitHub Actions for tests, packaging, and Terraform validation. For deployment, the workable choices are an AWS CodePipeline source connection to GitHub, or manual Terraform deployment from the authenticated workstation.

The project directory currently has no `.git` directory and no GitHub remote. The local GitHub CLI is logged into `ep-asim`, but GitHub returns `404` for the supplied `AW-0811/Agentcore-terraform-upskilling` repository under that login. Confirm the owner/name or grant the logged-in identity access before pushing or connecting a pipeline.

## Safe release sequence

1. Review the Terraform plan. It should import and set retention on the existing log group, then create the dashboard and two alarms. It must not create or replace `incident_triage_demo`.
2. Keep `terraform.tfstate` out of Git. Before CI can run Terraform against AWS, migrate this local state to a versioned, private S3 backend with S3 lockfile support.
3. Add the selected CI/CD workflow only after confirming repository visibility, default branch, and the AWS deployment route.
4. Use a manual deploy gate initially. Review each plan before apply, then rerun the two live smoke cases and check their request IDs in CloudWatch.

## References

- [AgentCore runtime metrics](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-runtime-metrics.html)
- [Configure AgentCore observability](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-configure.html)
- [AWS managed project policies](https://docs.aws.amazon.com/accounts/latest/reference/scps-and-rcps-for-projects.html)
- [Terraform S3 backend guidance](https://docs.aws.amazon.com/prescriptive-guidance/latest/terraform-aws-provider-best-practices/backend.html)
