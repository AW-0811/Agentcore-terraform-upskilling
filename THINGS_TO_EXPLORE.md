# Future scope and next steps

The current project is a working learning demo: AgentCore runs the agent, OpenTelemetry traces its request/evidence/model steps, CloudWatch holds runtime logs and service metrics, and Terraform manages the AWS dashboard and alarms. The ideas below extend that baseline. They are options to evaluate, not prerequisites for the current demo.

## 1. Make operational signals more useful

Add application-level counters and measurements for successful triage requests, evidence lookup failures, OpenAI request failures, and model input/output tokens. Keep dimensions low-cardinality (for example, status and model name); do not use request IDs or raw incident text as metric dimensions. Put a few meaningful signals beside AgentCore's built-in invocation, latency, throttle, and error metrics.

This would answer questions the current service metrics cannot, such as “How often does evidence fail?” and “How many model tokens did this workload use?” The OpenAI span already records token attributes; trend them only after checking that the telemetry pipeline exports them in a useful, privacy-conscious way.

## 2. Choose a dashboard path

| Option | What it means here | Advantages | Trade-offs |
| --- | --- | --- | --- |
| **Keep CloudWatch dashboards** | Keep the existing Terraform-managed dashboard and alarms; add useful widgets and SNS notifications. | Fewest new services; AWS runtime metrics and logs stay in their native home; existing Terraform workflow already manages it. | Dashboard experience is AWS-specific; combining data from other platforms can be less convenient. |
| **Add Grafana with CloudWatch as a data source** | Use Amazon Managed Grafana, Grafana Cloud, or self-managed Grafana to query existing CloudWatch metrics and logs. | More flexible panels and variables; can combine CloudWatch with other data sources; does not require moving AWS metrics into Prometheus. | Adds Grafana setup, IAM/data-source access, and potentially subscription or query costs. CloudWatch still stores the AWS metrics and logs. Terraform can still manage Grafana resources and dashboards; Grafana does not replace Terraform. |

**Practical next experiment:** keep CloudWatch as the data store and add Grafana only if you want to compare dashboard usability or expect to combine multiple data sources. This avoids introducing another metrics backend just to redraw the current graphs. Grafana's CloudWatch data source can query CloudWatch metrics and logs; it does not itself store those AWS signals.

## 3. Decide whether Prometheus is useful

Prometheus is a metrics format, query language, and monitoring ecosystem. Amazon Managed Service for Prometheus (AMP) is an AWS-managed, Prometheus-compatible metrics backend. It is useful when an application or platform exposes Prometheus-compatible metrics, you want PromQL, or you want a shared metrics backend for several workloads.

For this demo, AgentCore's built-in runtime metrics are already available in CloudWatch. Adding AMP does **not** automatically move or expose those metrics there. To use Prometheus here, first add application metrics and a supported collector/export path (for example, OpenTelemetry/ADOT remote write), or deliberately forward CloudWatch metrics using a suitable integration. That adds ingestion, IAM, retention, and cost considerations. A Prometheus backend is likely unnecessary for the current single-agent demo unless learning PromQL/AMP is itself the goal.

Grafana can query either CloudWatch or a Prometheus-compatible backend such as AMP. Prometheus is not required in order to use Grafana.

## 4. Finish the alert path

The two CloudWatch alarms detect AgentCore system errors and throttles, but currently have no notification actions. Add an SNS topic and confirmed subscription, attach an action to an alarm, and test the notification. Then document who responds and what the alarm should prompt them to check.

## 5. Add service objectives and safer release gates

Define a small set of measurable objectives, such as successful invocation rate, p95 response latency, and evidence-tool failure rate. Display them with a suitable lookback window and alert only when the signal is actionable. Later, introduce a separate staging environment and consider requiring smoke checks and objective thresholds before promotion. Keep the current manual Terraform approval until rollback and alert behavior are clear.

## Suggested order

1. Add and verify application-level metrics, especially request status and token usage.
2. Configure and test alarm notifications.
3. Improve the existing CloudWatch dashboard.
4. Try Grafana against CloudWatch if a more flexible dashboard or multi-source view would help.
5. Add AMP/Prometheus only when there is a concrete PromQL, portability, or shared-metrics need.
6. Add staging and release thresholds after the signals are reliable.

## References

- [Grafana Amazon CloudWatch data source](https://grafana.com/docs/grafana/latest/datasources/aws-cloudwatch/)
- [Amazon Managed Service for Prometheus ingestion options](https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-ingest-methods.html)
- [ADOT metrics collection for Amazon Managed Service for Prometheus](https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-ingest-metrics-OpenTelemetry.html)
- [CloudWatch dashboards](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch_Dashboards.html)
