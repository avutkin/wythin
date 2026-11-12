"""Language selection at the /insights request-to-model boundary."""

from __future__ import annotations

import pytest
from httpx import ASGITransport, AsyncClient

from server.main import app
from server.routers.insights import get_openai_client, require_ai_consent


class CapturingCompletions:
    def __init__(self):
        self.kwargs = None

    async def create(self, **kwargs):
        self.kwargs = kwargs
        message = type("Message", (), {"content": "  Хороший результат.  "})()
        choice = type("Choice", (), {"message": message})()
        return type("Completion", (), {"choices": [choice]})()


class CapturingClient:
    def __init__(self):
        self.completions = CapturingCompletions()
        self.chat = type("Chat", (), {"completions": self.completions})()


async def post_insight(payload):
    fake = CapturingClient()
    app.dependency_overrides[require_ai_consent] = lambda: "consented-device"
    app.dependency_overrides[get_openai_client] = lambda: fake
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post("/insights", json=payload)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
        app.dependency_overrides.pop(require_ai_consent, None)
    return response, fake.completions.kwargs


MODE_PAYLOADS = [
    {"mode": "activity", "activity_type": "Breathwork", "before_dc": 20, "during_dc": 30},
    {"mode": "live_state", "window_minutes": 10,
     "metrics": {"dc": {"now": 12, "min": 10, "max": 14}}},
    {"mode": "day_potential", "anchor_hour": 7, "baseline_sufficient": False},
    {"mode": "macro_trend", "period": "week", "range_label": "Oct 1–7",
     "trends": {"dc": {"avg": 12, "baseline": 10}}},
    {"mode": "sleep", "sleep": {"asleep_min": 400,
     "arcs": {"dc": {"first_half": 10, "second_half": 12}}}},
]


@pytest.mark.asyncio
@pytest.mark.parametrize("payload", MODE_PAYLOADS, ids=[p["mode"] for p in MODE_PAYLOADS])
async def test_russian_request_tells_model_to_write_russian_without_changing_mode_structure(payload):
    response, sent = await post_insight({**payload, "language": "ru"})

    assert response.status_code == 200
    assert response.json() == {"text": "Хороший результат."}
    system = sent["messages"][0]["content"]
    assert "Russian" in system
    assert "not translate" in system.lower() or "keep" in system.lower()
    assert sent["messages"][1]["content"]
    if payload["mode"] == "live_state":
        assert "<state_key> |" in system
        assert "engaged_performing" in system


@pytest.mark.asyncio
@pytest.mark.parametrize("payload", [MODE_PAYLOADS[0], MODE_PAYLOADS[1], MODE_PAYLOADS[3], MODE_PAYLOADS[4]],
                         ids=["activity", "live_state", "macro_trend", "sleep"])
async def test_russian_metric_input_uses_screen_glossary(payload):
    response, sent = await post_insight({**payload, "language": "ru"})

    assert response.status_code == 200
    assert "Вагусный тонус" in sent["messages"][1]["content"]


@pytest.mark.asyncio
async def test_omitted_language_keeps_english_prompt_and_input():
    response, sent = await post_insight(MODE_PAYLOADS[0])

    assert response.status_code == 200
    assert "Russian" not in sent["messages"][0]["content"]
    assert "Vagal Tone" in sent["messages"][1]["content"]
    assert "Вагусный тонус" not in sent["messages"][1]["content"]


@pytest.mark.asyncio
async def test_russian_activity_keeps_recommendation_line_with_russian_label():
    response, sent = await post_insight({**MODE_PAYLOADS[0], "language": "ru"})

    assert response.status_code == 200
    system = sent["messages"][0]["content"]
    assert "В следующий раз: <" in system
    assert "Next session: <" not in system


@pytest.mark.asyncio
async def test_russian_macro_trend_has_token_room_for_cyrillic_text():
    english_response, english_sent = await post_insight(MODE_PAYLOADS[3])
    russian_response, russian_sent = await post_insight({**MODE_PAYLOADS[3], "language": "ru"})

    assert english_response.status_code == russian_response.status_code == 200
    assert english_sent["max_tokens"] == 150
    assert russian_sent["max_tokens"] > english_sent["max_tokens"]


@pytest.mark.asyncio
@pytest.mark.parametrize("language", ["fr", "RU", "", None])
async def test_unsupported_language_is_rejected(language):
    response, sent = await post_insight({**MODE_PAYLOADS[0], "language": language})

    assert response.status_code == 422
    assert sent is None
