"""Reject Terraform release plans with unexpected infrastructure actions."""

from __future__ import annotations

import json
import sys


ALLOWED_ACTIONS = {
    "aws_bedrockagentcore_agent_runtime.triage": {("update",)},
    "aws_s3_object.agent": {("create", "delete")},
    "aws_cloudwatch_log_group.agent_runtime": {("update",)},
    "aws_cloudwatch_dashboard.agent_runtime": {("create",), ("update",)},
    "aws_cloudwatch_metric_alarm.system_errors": {("create",), ("update",)},
    "aws_cloudwatch_metric_alarm.throttles": {("create",), ("update",)},
}


def main() -> int:
    plan = json.load(sys.stdin)
    unexpected: list[str] = []

    for item in plan.get("resource_changes", []):
        if item.get("mode") != "managed":
            continue
        address = item["address"]
        actions = tuple(item["change"]["actions"])
        if actions == ("no-op",):
            continue

        print(f"{address}: {' '.join(actions)}")
        if address not in ALLOWED_ACTIONS or actions not in ALLOWED_ACTIONS[address]:
            unexpected.append(f"{address}: {' '.join(actions)}")

    if unexpected:
        print("Release plan contains unapproved Terraform actions:", file=sys.stderr)
        for action in unexpected:
            print(f"  {action}", file=sys.stderr)
        print(
            "The existing AgentCore runtime must never be created or replaced by this pipeline.",
            file=sys.stderr,
        )
        return 1

    print("Release plan passed the resource-action guard.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
