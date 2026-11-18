import json
from asyncio import run
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

import pytest

import main
from triage import triage


def test_triage_returns_evidence_and_calls_the_model_once():
    calls = []

    async def summarize(question, events):
        calls.append(question)
        assert [event["id"] for event in events] == ["evt-001", "evt-002"]
        return "Check the connection pool."

    result = run(triage({"question": "Why is checkout returning 503s?"}, summarize))

    assert result == {
        "status": "ok",
        "summary": "Check the connection pool.",
        "evidence_ids": ["evt-001", "evt-002"],
    }
    assert calls == ["Why is checkout returning 503s?"]


async def no_model_call(*args):
    pytest.fail("The model should not be called")


def test_tool_failure_reports_missing_evidence_without_calling_the_model():
    result = run(
        triage(
            {"question": "Why is checkout down?", "scenario": "tool_failure"},
            no_model_call,
        )
    )

    assert result["status"] == "evidence_unavailable"
    assert result["evidence_ids"] == []


@pytest.mark.parametrize(
    "payload", [[], {}, {"question": 7}, {"question": "Hi", "scenario": []}]
)
def test_invalid_input_never_calls_the_model(payload):
    assert run(triage(payload, no_model_call))["status"] == "invalid_request"


def test_agent_runner_uses_responses_with_bounded_output(monkeypatch):
    run_agent = AsyncMock(
        return_value=SimpleNamespace(
            final_output="Check the connection pool.",
            context_wrapper=SimpleNamespace(
                usage=SimpleNamespace(input_tokens=25, output_tokens=5)
            ),
        )
    )
    monkeypatch.setattr(main, "openai_client", Mock())
    monkeypatch.setattr(main.Runner, "run", run_agent)

    result = run(
        triage({"question": "Why is checkout returning 503s?"}, main.openai_summary)
    )

    assert result["summary"] == "Check the connection pool."
    assert result["evidence_ids"] == ["evt-001", "evt-002"]
    run_agent.assert_awaited_once()
    agent, prompt = run_agent.call_args.args
    assert isinstance(agent.model, main.OpenAIResponsesModel)
    assert agent.model.model == "gpt-6-luna"
    assert agent.model_settings.reasoning.effort == "medium"
    assert agent.model_settings.store is False
    assert agent.model_settings.max_tokens == 1024
    assert run_agent.call_args.kwargs["max_turns"] == 1
    assert run_agent.call_args.kwargs["run_config"].tracing_disabled is True
    assert [event["id"] for event in json.loads(prompt)["events"]] == result[
        "evidence_ids"
    ]


def test_openai_client_reads_only_the_configured_secret(monkeypatch):
    secret_arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:demo-abc123"
    monkeypatch.setenv("TRIAGE_OPENAI_SECRET_ARN", secret_arn)
    secrets = Mock()
    secrets.get_secret_value.return_value = {
        "SecretString": '{"OPENAI_API_KEY":"example-test-value"}'
    }
    aws_client = Mock(return_value=secrets)
    new_openai_client = Mock()
    monkeypatch.setattr(main.boto3, "client", aws_client)
    monkeypatch.setattr(main, "AsyncOpenAI", new_openai_client)

    main.openai_client.cache_clear()
    try:
        assert main.openai_client() is new_openai_client.return_value
    finally:
        main.openai_client.cache_clear()

    assert aws_client.call_args.args == ("secretsmanager",)
    assert aws_client.call_args.kwargs["region_name"] == "us-east-2"
    secrets.get_secret_value.assert_called_once_with(SecretId=secret_arn)
    new_openai_client.assert_called_once_with(
        api_key="example-test-value",
        base_url="https://api.openai.com/v1",
        max_retries=0,
        timeout=25.0,
    )
