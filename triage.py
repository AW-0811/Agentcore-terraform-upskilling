from collections.abc import Awaitable, Callable

from opentelemetry import trace

TRACER = trace.get_tracer(__name__)

CHECKOUT_ERRORS = (
    {
        "id": "evt-001",
        "message": "Checkout returned HTTP 503 after a database connection timeout.",
    },
    {
        "id": "evt-002",
        "message": "The checkout database connection pool was exhausted.",
    },
)

Summarize = Callable[[str, tuple[dict[str, str], ...]], Awaitable[str]]


class EvidenceUnavailable(Exception):
    """The demo evidence source failed."""


def get_recent_errors(scenario: str) -> tuple[dict[str, str], ...]:
    with TRACER.start_as_current_span("get_recent_errors"):
        if scenario == "tool_failure":
            raise EvidenceUnavailable("Simulated log lookup failure")
        return CHECKOUT_ERRORS


async def triage(payload: object, summarize: Summarize) -> dict:
    if not isinstance(payload, dict):
        return {"status": "invalid_request", "error": "Send a JSON object."}

    question = payload.get("question")
    scenario = payload.get("scenario", "incident")
    if not isinstance(question, str) or not 1 <= len(question.strip()) <= 500:
        return {
            "status": "invalid_request",
            "error": "Send a question of 1 to 500 characters.",
        }
    if scenario not in ("incident", "tool_failure"):
        return {"status": "invalid_request", "error": "Use incident or tool_failure."}

    try:
        events = get_recent_errors(scenario)
    except EvidenceUnavailable:
        return {
            "status": "evidence_unavailable",
            "summary": "Checkout log evidence is unavailable. Check the log source and retry.",
            "evidence_ids": [],
        }

    return {
        "status": "ok",
        "summary": await summarize(question.strip(), events),
        "evidence_ids": [event["id"] for event in events],
    }
