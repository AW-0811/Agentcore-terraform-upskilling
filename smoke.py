import argparse
import json
from contextlib import closing
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from uuid import uuid4

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError


def check(send, mode: str) -> None:
    request = {"question": "Why is checkout returning 503s?"}
    cases = (
        ("incident", "ok", ["evt-001", "evt-002"]),
        ("tool_failure", "evidence_unavailable", []),
    )
    failures = []
    for scenario, status, evidence_ids in cases:
        try:
            result = send({**request, "scenario": scenario})
        except HTTPError as error:
            failures.append(f"{scenario}: HTTP {error.code}")
            continue
        except ClientError as error:
            failures.append(f"{scenario}: {error.response['Error']['Code']}")
            continue
        except (BotoCoreError, URLError, TimeoutError, ValueError) as error:
            failures.append(f"{scenario}: {type(error).__name__}")
            continue
        if (
            result.get("mode") != mode
            or result.get("status") != status
            or result.get("evidence_ids") != evidence_ids
            or not result.get("summary")
        ):
            failures.append(f"{scenario}: unexpected response")
            continue
        print(f"{scenario}: {status} (request {result['request_id']})")
    if failures:
        raise SystemExit("Smoke checks failed:\n" + "\n".join(failures))


def invoke_local(payload: dict) -> dict:
    request = Request(
        "http://127.0.0.1:8080/invocations",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urlopen(request, timeout=45) as response:
        return json.load(response)


def check_runtime(runtime_arn: str) -> None:
    session = boto3.Session(profile_name="agentcore-test", region_name="us-east-2")
    client = session.client(
        "bedrock-agentcore",
        config=Config(
            retries={"total_max_attempts": 1}, connect_timeout=5, read_timeout=90
        ),
    )

    def invoke_runtime(payload: dict) -> dict:
        response = client.invoke_agent_runtime(
            agentRuntimeArn=runtime_arn,
            qualifier="DEFAULT",
            runtimeSessionId=str(uuid4()),
            contentType="application/json",
            accept="application/json",
            payload=json.dumps(payload).encode(),
        )
        with closing(response["response"]) as stream:
            return json.loads(stream.read())

    check(invoke_runtime, "openai")


def main() -> None:
    parser = argparse.ArgumentParser(description="Check both incident triage outcomes.")
    target = parser.add_mutually_exclusive_group()
    target.add_argument(
        "--runtime-arn", help="Explicitly run the check against deployed AgentCore."
    )
    target.add_argument(
        "--local-live",
        action="store_true",
        help="Expect real OpenAI mode on localhost.",
    )
    args = parser.parse_args()
    if args.runtime_arn:
        check_runtime(args.runtime_arn)
    else:
        check(invoke_local, "openai" if args.local_live else "offline")


if __name__ == "__main__":
    main()
