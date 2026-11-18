# Things to explore

These exercises build on the reproducible setup in the [README](README.md) and [CICD.md](CICD.md). Use your own isolated AWS deployment and review Terraform plans before applying them.

## Add a real evidence source

Replace the fixed sample events with a read-only evidence source such as sanitized application logs. Give the tool a narrow query interface, cap result count and time range, and return source IDs and timestamps so a human can verify the evidence. Keep incident text and credentials out of telemetry unless there is a clear need and suitable access controls.

## Add a specialist agent

Add one specialist that turns evidence into an investigation checklist. Start with a deterministic route so the same request exercises the same path each time. Add trace spans around each agent and compare output quality, latency, token usage, and tool calls against the single-agent baseline.

## Compare separate AgentCore runtimes

Try hosting the specialist in a second runtime and invoking it from the triage agent. Give each runtime its own least-privilege role. Measure the additional latency and inspect whether trace context connects the caller and specialist; if not, correlate them with request IDs.

## Add a notification path

The CloudWatch alarms currently have no actions. Create a confirmed SNS subscription and attach it to one alarm, then deliberately trigger a test alarm and verify receipt. Decide who owns the alert and what they should do before enabling paging.

## Strengthen delivery safely

The current pipeline reviews a Terraform plan and runs post-deployment smoke checks. A useful next step is an isolated staging environment and measurable release gates, such as passing tests, no disallowed resource actions, and successful smoke checks. Keep human review until rollback and alerting behavior are understood.

## Learn the AgentCore observability view

Open a successful trace and a tool-failure trace. Follow the request span through evidence lookup and the model call, then compare the trace with the runtime log using the request ID. The traces include OpenAI token usage attributes; consider building a separate dashboard or report if you need to trend those values over time.
