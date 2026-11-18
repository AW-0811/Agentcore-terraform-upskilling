import json
import logging
import os
from asyncio import to_thread
from functools import cache
from uuid import uuid4

import boto3
from agents import Agent, ModelSettings, OpenAIResponsesModel, RunConfig, Runner
from agents.exceptions import ModelBehaviorError
from bedrock_agentcore import BedrockAgentCoreApp
from botocore.config import Config
from openai import APIConnectionError, APIStatusError, AsyncOpenAI
from openai.types.shared import Reasoning
from opentelemetry import trace

from triage import triage

app = BedrockAgentCoreApp()
logger = logging.getLogger(__name__)
tracer = trace.get_tracer(__name__)
OPENAI_MODEL = "gpt-6-luna"
REASONING_EFFORT = "medium"


@cache
def openai_client() -> AsyncOpenAI:
    secret_arn = os.environ.get("TRIAGE_OPENAI_SECRET_ARN")
    if secret_arn:
        secrets = boto3.client(
            "secretsmanager",
            region_name="us-east-2",
            config=Config(connect_timeout=5, read_timeout=10),
        )
        value = secrets.get_secret_value(SecretId=secret_arn).get("SecretString", "")
        try:
            secret = json.loads(value)
        except json.JSONDecodeError:
            raise RuntimeError("The OpenAI secret must be a JSON object.") from None
        api_key = secret.get("OPENAI_API_KEY") if isinstance(secret, dict) else None
    else:
        api_key = os.environ.get("OPENAI_API_KEY")

    if not isinstance(api_key, str) or not api_key.strip():
        raise RuntimeError("Configure OPENAI_API_KEY for this agent.")
    return AsyncOpenAI(
        api_key=api_key.strip(),
        base_url="https://api.openai.com/v1",
        max_retries=0,
        timeout=25.0,
    )


async def openai_summary(question: str, events: tuple[dict[str, str], ...]) -> str:
    with tracer.start_as_current_span("openai.responses") as span:
        span.set_attribute("gen_ai.provider.name", "openai")
        span.set_attribute("gen_ai.request.model", OPENAI_MODEL)
        span.set_attribute("triage.reasoning_effort", REASONING_EFFORT)
        try:
            client = await to_thread(openai_client)
            agent = Agent(
                name="Checkout Incident Triage",
                model=OpenAIResponsesModel(model=OPENAI_MODEL, openai_client=client),
                instructions=(
                    "Summarize the likely checkout incident cause and one next check "
                    "in two short sentences. Use only the supplied sample events as "
                    "evidence. If the events are insufficient, say so."
                ),
                model_settings=ModelSettings(
                    reasoning=Reasoning(effort=REASONING_EFFORT),
                    max_tokens=1024,
                    store=False,
                ),
            )
            result = await Runner.run(
                agent,
                json.dumps({"question": question, "events": events}),
                max_turns=1,
                run_config=RunConfig(tracing_disabled=True),
            )
        except APIStatusError as error:
            raise RuntimeError(
                f"OpenAI Responses request failed (HTTP {error.status_code})."
            ) from None
        except APIConnectionError:
            raise RuntimeError(
                "OpenAI Responses request could not connect or timed out."
            ) from None
        except ModelBehaviorError:
            raise RuntimeError("OpenAI did not return a complete summary.") from None

        usage = result.context_wrapper.usage
        span.set_attribute("gen_ai.usage.input_tokens", usage.input_tokens)
        span.set_attribute("gen_ai.usage.output_tokens", usage.output_tokens)
        summary = result.final_output
        if not isinstance(summary, str) or not summary.strip():
            raise RuntimeError("OpenAI did not return a complete summary.")
        logger.info(
            "OpenAI summary generated, model=%s effort=%s",
            OPENAI_MODEL,
            REASONING_EFFORT,
        )
        return summary.strip()


async def offline_summary(_question: str, _events: tuple[dict[str, str], ...]) -> str:
    return (
        "Checkout likely timed out because the database connection pool was full. "
        "Check how many database connections are in use."
    )


@app.entrypoint
async def invoke(payload):
    offline = os.environ.get("TRIAGE_OFFLINE") == "1"
    request_id = uuid4().hex
    with tracer.start_as_current_span("incident_triage") as span:
        span.set_attribute("triage.request_id", request_id)
        result = await triage(payload, offline_summary if offline else openai_summary)
        span.set_attribute("triage.status", result["status"])
        logger.info("request_id=%s status=%s", request_id, result["status"])
        return {
            **result,
            "request_id": request_id,
            "mode": "offline" if offline else "openai",
        }


if __name__ == "__main__":
    app.run(host=os.environ.get("TRIAGE_HOST", "127.0.0.1"))
