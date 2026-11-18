# Observability

## Signals in this project

The agent uses OpenTelemetry instrumentation. It creates spans for the overall triage request, the evidence lookup, and the OpenAI Responses call. The OpenAI span records provider/model, reasoning effort, and input/output token counts. The request span records a generated request ID and response status. The app logs the request ID and status, which helps connect an invocation with its runtime log records.

Amazon Bedrock AgentCore emits service metrics for runtime invocations, errors, throttles, latency, overhead, and resource usage. AgentCore runtime logs and traces can be inspected through the AgentCore Observability view and the configured AWS telemetry destination in CloudWatch. In the AWS console, select the runtime and endpoint in the selected Region, then inspect its traces, spans, and logs. CloudWatch Logs Insights can search runtime log streams by request ID.

## Terraform-managed CloudWatch resources

`observability.tf` configures:

- A dashboard for invocation counts, system/user errors, throttles, p95 latency, runtime overhead, and CPU/memory usage.
- A metric alarm for runtime system errors and another for throttles. Missing data is treated as non-breaching so an idle demo does not alarm.
- 30-day retention for the AgentCore runtime log group. An import block adopts the service-created group, and `prevent_destroy` protects it against accidental deletion through Terraform.

The dashboard displays AgentCore service metrics; it is not a datastore. Metrics are stored/retained by CloudWatch Metrics according to AWS service behavior. Runtime logs are stored in CloudWatch Logs. The runtime's trace destination is configured separately through AgentCore observability settings; this project has used CloudWatch Transaction Search for trace discovery. Review that setting in your own environment rather than assuming the original owner's configuration transfers with the repository.

## Alerts and costs

The alarms currently have no actions. They change state in CloudWatch but do not email, text, or page anyone. To receive notifications, configure an SNS topic (or another supported action) and confirm a subscription. Runtime resource usage telemetry can arrive with a delay, so use it for trends and cost context rather than immediate incident response.

CloudWatch dashboards, alarms, log ingestion/retention, and trace indexing may incur charges. Check current pricing and your AWS spend settings before enabling higher-volume telemetry.

## What this does not cover

- No external production log system is connected; the evidence source is sample data.
- There is no custom dashboard panel for OpenAI token usage, although the OpenAI call span records input and output token attributes.
- There is no paging/notification route, SLO, synthetic monitor, or long-term metrics export configured.
- Trace/log contents may be sensitive. Avoid recording secrets or unnecessary incident payloads; inspect what your runtime emits and apply suitable retention and access controls.

## References

- [AgentCore runtime metrics](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-runtime-metrics.html)
- [Configure AgentCore observability](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-configure.html)
- [View AgentCore observability data](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-view.html)
- [CloudWatch Transaction Search](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Enable-TransactionSearch.html)
