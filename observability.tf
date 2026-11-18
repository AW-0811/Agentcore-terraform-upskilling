locals {
  runtime_arn             = aws_bedrockagentcore_agent_runtime.triage.agent_runtime_arn
  runtime_id              = split("/", local.runtime_arn)[1]
  runtime_endpoint_label  = "${local.runtime_name}::DEFAULT"
  runtime_log_group_name  = "/aws/bedrock-agentcore/runtimes/${local.runtime_id}-DEFAULT"
  observability_dashboard = "incident-triage-agentcore-observability"
}

import {
  to = aws_cloudwatch_log_group.agent_runtime
  id = local.runtime_log_group_name
}

resource "aws_cloudwatch_log_group" "agent_runtime" {
  name              = local.runtime_log_group_name
  retention_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_cloudwatch_metric_alarm" "system_errors" {
  alarm_name        = "incident-triage-agentcore-system-errors"
  alarm_description = "AgentCore reported one or more system errors in a five-minute window."
  namespace         = "AWS/Bedrock-AgentCore"
  metric_name       = "SystemErrors"
  dimensions = {
    Resource  = local.runtime_arn
    Operation = "InvokeAgentRuntime"
    Name      = local.runtime_endpoint_label
  }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "throttles" {
  alarm_name        = "incident-triage-agentcore-throttles"
  alarm_description = "AgentCore throttled one or more runtime invocations in a five-minute window."
  namespace         = "AWS/Bedrock-AgentCore"
  metric_name       = "Throttles"
  dimensions = {
    Resource  = local.runtime_arn
    Operation = "InvokeAgentRuntime"
    Name      = local.runtime_endpoint_label
  }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_dashboard" "agent_runtime" {
  dashboard_name = local.observability_dashboard
  dashboard_body = jsonencode({
    start          = "-PT12H"
    periodOverride = "inherit"
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 1
        properties = {
          markdown = "# Incident triage AgentCore runtime\nMetrics and alarm state for ${local.runtime_name} in ${local.region}."
        }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 1
        width  = 24
        height = 3
        properties = {
          title = "Runtime alarms"
          alarms = [
            aws_cloudwatch_metric_alarm.system_errors.arn,
            aws_cloudwatch_metric_alarm.throttles.arn,
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 4
        width  = 12
        height = 6
        properties = {
          title  = "Invocations and errors"
          view   = "timeSeries"
          region = local.region
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/Bedrock-AgentCore", "Invocations", "Resource", local.runtime_arn, "Operation", "InvokeAgentRuntime", "Name", local.runtime_endpoint_label, { id = "m1", label = "Invocations", stat = "Sum" }],
            ["AWS/Bedrock-AgentCore", "SystemErrors", "Resource", local.runtime_arn, "Operation", "InvokeAgentRuntime", "Name", local.runtime_endpoint_label, { id = "m2", label = "System errors", stat = "Sum" }],
            ["AWS/Bedrock-AgentCore", "UserErrors", "Resource", local.runtime_arn, "Operation", "InvokeAgentRuntime", "Name", local.runtime_endpoint_label, { id = "m3", label = "User errors", stat = "Sum" }],
            ["AWS/Bedrock-AgentCore", "Throttles", "Resource", local.runtime_arn, "Operation", "InvokeAgentRuntime", "Name", local.runtime_endpoint_label, { id = "m4", label = "Throttles", stat = "Sum" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 4
        width  = 12
        height = 6
        properties = {
          title  = "End-to-end and runtime overhead latency (p95)"
          view   = "timeSeries"
          region = local.region
          period = 60
          metrics = [
            ["AWS/Bedrock-AgentCore", "Latency", "Resource", local.runtime_arn, "Operation", "InvokeAgentRuntime", "Name", local.runtime_endpoint_label, { id = "m1", label = "End-to-end latency", stat = "p95" }],
            ["AWS/Bedrock-AgentCore", "OverheadLatency", "Resource", local.runtime_arn, "Operation", "InvokeAgentRuntime", "Name", local.runtime_endpoint_label, { id = "m2", label = "AgentCore overhead", stat = "p95" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 10
        width  = 24
        height = 6
        properties = {
          title  = "Runtime resource use (telemetry; may lag by up to 60 minutes)"
          view   = "timeSeries"
          region = local.region
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/Bedrock-AgentCore", "CPUUsed-vCPUHours", "Service", "AgentCore.Runtime", "Resource", local.runtime_arn, "Name", local.runtime_endpoint_label, { id = "m1", label = "CPU vCPU-hours", stat = "Sum" }],
            ["AWS/Bedrock-AgentCore", "MemoryUsed-GBHours", "Service", "AgentCore.Runtime", "Resource", local.runtime_arn, "Name", local.runtime_endpoint_label, { id = "m2", label = "Memory GB-hours", stat = "Sum" }],
          ]
        }
      },
    ]
  })
}
