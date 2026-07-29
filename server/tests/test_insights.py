"""
Tests for POST /insights — the OpenAI client is swapped for a fake via
FastAPI's dependency_overrides, so no real API calls are made.
"""
from __future__ import annotations

import pytest
from httpx import AsyncClient, ASGITransport
from openai import OpenAIError

from server.main import app
from server.routers.insights import get_openai_client


class _FakeMessage:
    def __init__(self, content):
        self.content = content


class _FakeChoice:
    def __init__(self, content):
        self.message = _FakeMessage(content)


class _FakeCompletion:
    def __init__(self, content):
        self.choices = [_FakeChoice(content)]


class _FakeChatCompletions:
    def __init__(self, content=None, raise_error=False):
        self._content = content
        self._raise_error = raise_error

    async def create(self, **kwargs):
        if self._raise_error:
            raise OpenAIError("boom")
        return _FakeCompletion(self._content)


class _FakeChat:
    def __init__(self, completions):
        self.completions = completions


class _FakeOpenAIClient:
    def __init__(self, content=None, raise_error=False):
        self.chat = _FakeChat(_FakeChatCompletions(content=content, raise_error=raise_error))


_PAYLOAD = {
    "activity_type": "Breathwork",
    "activity_subtype": "Box Breathing",
    "duration_min": 10,
    "before_rsa": 20.0,
    "during_rsa": 32.0,
    "after_rsa": 28.0,
}

_LIVE_STATE_PAYLOAD = {
    "mode": "live_state",
    "window_minutes": 10,
    "metrics": {
        "hr":  {"start": 68.0, "end": 62.0, "min": 60.0, "max": 70.0, "mean": 65.0, "direction": "falling"},
        "rsa": {"start": 22.0, "end": 34.0, "min": 20.0, "max": 36.0, "mean": 28.0, "direction": "rising"},
    },
}


@pytest.mark.asyncio
async def test_generate_insight_success():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(
        content="  Solid session — your RSA improved nicely.  "
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 200
    assert r.json()["text"] == "Solid session — your RSA improved nicely."


@pytest.mark.asyncio
async def test_generate_insight_openai_error_returns_502():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(raise_error=True)
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 502


@pytest.mark.asyncio
async def test_generate_insight_empty_response_returns_502():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="")
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 502


def test_get_openai_client_requires_api_key(monkeypatch):
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    with pytest.raises(RuntimeError):
        get_openai_client()


@pytest.mark.asyncio
async def test_generate_live_state_insight_success():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(
        content="  Your heart rate has been gradually settling over the last 10 minutes.  "
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_LIVE_STATE_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 200
    assert r.json()["text"] == "Your heart rate has been gradually settling over the last 10 minutes."


@pytest.mark.asyncio
async def test_generate_live_state_insight_missing_metrics_returns_422():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient()
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json={"mode": "live_state", "window_minutes": 10})
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
    assert r.status_code == 422


@pytest.mark.asyncio
async def test_generate_activity_insight_missing_activity_type_returns_422():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient()
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json={"mode": "activity"})
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
    assert r.status_code == 422


# --- day_potential mode -----------------------------------------------------

_DAY_POTENTIAL_PAYLOAD = {
    "mode": "day_potential",
    "score": 72,
    "band": "good",
    "anchor_hour": 7.2,
    "anchor_duration_min": 5,
    "late": False,
    "confidence": "high",
    "components": {"recovery_capacity": {"z": 0.8, "level": "top of usual"}},
    "modifiers": {"fragmentation": 0.0},
    "baseline_anchors": 41,
    "baseline_target": 60,
    "baseline_sufficient": True,
    "recent": [64, 58, 61, 66, 69, 70, 72],
    "streak_current": 4,
    "streak_best": 6,
    "grace_used": False,
}


@pytest.mark.asyncio
async def test_day_potential_success():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(
        content="Good Reserves\n• a\n• b\n→ c"
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_DAY_POTENTIAL_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 200
    assert r.json()["text"].startswith("Good Reserves")


@pytest.mark.asyncio
async def test_day_potential_requires_score_when_baseline_sufficient():
    payload = {k: v for k, v in _DAY_POTENTIAL_PAYLOAD.items() if k != "score"}
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="x")
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=payload)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 422


@pytest.mark.asyncio
async def test_day_potential_allows_recent_when_baseline_insufficient():
    payload = dict(_DAY_POTENTIAL_PAYLOAD)
    payload.pop("score")
    payload["baseline_sufficient"] = False
    payload["baseline_anchors"] = 3
    payload["recent"] = [58, 61, 64]
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(
        content="Learning\n• a\n• b\n→ c"
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=payload)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 200


@pytest.mark.asyncio
async def test_day_potential_rejects_missing_anchor():
    payload = {k: v for k, v in _DAY_POTENTIAL_PAYLOAD.items() if k != "anchor_hour"}
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="x")
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=payload)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 422


@pytest.mark.asyncio
async def test_day_potential_provisional_requires_a_score():
    """A provisional baseline still produces a number — a request claiming one
    without a score is malformed."""
    payload = {k: v for k, v in _DAY_POTENTIAL_PAYLOAD.items() if k != "score"}
    payload["baseline_sufficient"] = False
    payload["provisional"] = True
    payload["baseline_anchors"] = 3
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="x")
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=payload)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 422


@pytest.mark.asyncio
async def test_day_potential_provisional_with_a_score_succeeds():
    payload = dict(_DAY_POTENTIAL_PAYLOAD)
    payload["baseline_sufficient"] = False
    payload["provisional"] = True
    payload["baseline_anchors"] = 3
    payload["baseline_target"] = 7
    payload["recent"] = [58, 61, 64]
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(
        content="Early Days\n• a\n• b\n→ c"
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=payload)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 200


@pytest.mark.asyncio
async def test_day_potential_first_morning_needs_neither_score_nor_recent():
    """The very first anchor has no reference day at all. That is a real state,
    not a malformed request."""
    payload = {k: v for k, v in _DAY_POTENTIAL_PAYLOAD.items()
               if k not in ("score", "recent")}
    payload["baseline_sufficient"] = False
    payload["provisional"] = False
    payload["baseline_anchors"] = 1
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(
        content="First One\n• a\n• b\n→ c"
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=payload)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 200


def test_day_potential_format_marks_a_provisional_score_as_early():
    from server.models import InsightRequest
    from server.routers.insights import _format_day_potential

    req = InsightRequest(
        mode="day_potential", score=61, band="good", anchor_hour=7.2,
        anchor_duration_min=5, late=False, confidence="high",
        baseline_anchors=3, baseline_target=7,
        baseline_sufficient=False, provisional=True)
    text = _format_day_potential(req)
    assert "61/100" in text
    assert "provisional" in text.lower()


def test_day_potential_format_says_no_reference_when_there_is_no_baseline():
    from server.models import InsightRequest
    from server.routers.insights import _format_day_potential

    req = InsightRequest(
        mode="day_potential", anchor_hour=7.2, anchor_duration_min=5,
        late=False, confidence="high", baseline_anchors=1, baseline_target=7,
        baseline_sufficient=False, provisional=False)
    text = _format_day_potential(req)
    assert "not yet available" in text.lower()


def test_day_potential_prompt_distinguishes_provisional_from_no_baseline():
    from server.routers.insights import _DAY_POTENTIAL_SYSTEM_PROMPT as p

    assert "provisional" in p.lower(), "prompt must cover the early-score case"
    # The old instruction told the model to claim no norms whenever the
    # baseline was insufficient, which now contradicts a score on screen.
    assert "claim no norms" in p, "the no-baseline branch must still exist"


def test_live_state_format_has_buckets_and_no_day_average():
    from server.models import InsightRequest, MetricTrend
    from server.routers.insights import _format_live_state

    req = InsightRequest(mode="live_state", window_minutes=10, metrics={
        "hr": MetricTrend(now=68.4, min=68.0, max=74.1,
                          buckets=[74.1, 72.8, 70.2, 68.9, 68.4],
                          slope_pct=-7.7, volatility="low", shape="steady-fall")
    })
    text = _format_live_state(req)
    assert "74.1 → 72.8" in text
    assert "steady-fall" in text
    assert "day_avg" not in text


def test_day_potential_format_includes_score_and_modifiers():
    from server.models import InsightRequest, MetricComponent
    from server.routers.insights import _format_day_potential

    req = InsightRequest(
        mode="day_potential", score=72, band="good", anchor_hour=7.2,
        anchor_duration_min=5, late=False, confidence="high",
        components={"recovery_capacity": MetricComponent(z=0.8, level="top of usual")},
        modifiers={"fragmentation": 4.0},
        baseline_anchors=41, baseline_target=60, baseline_sufficient=True,
        recent=[64, 70, 72], streak_current=4, streak_best=6, grace_used=False)
    text = _format_day_potential(req)
    assert "72/100" in text
    assert "modifier fragmentation: -4.0" in text
    assert "Streak: 4 mornings" in text


_MACRO_TREND_PAYLOAD = {
    "mode": "macro_trend",
    "period": "week",
    "range_label": "JUL 27 – AUG 2",
    "trends": {
        "dc": {
            "avg": 8.4, "baseline": 8.2, "delta_pct": 6.0,
            "days_above": 5, "days_total": 7, "direction": "higher",
        },
        "pip": {
            "avg": 52.0, "baseline": 57.0, "delta_pct": 9.0,
            "days_above": 6, "days_total": 7, "direction": "lower",
        },
        "stress_balance": {
            "avg": 44.0, "baseline": 48.0, "delta_pct": 8.0,
            "days_above": 5, "days_total": 7, "direction": "lower",
        },
    },
}


@pytest.mark.asyncio
async def test_macro_trend_success():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(
        content="Your recovery markers held steady this week.\n→ Keep the evening breathing."
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_MACRO_TREND_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 200
    assert "→" in r.json()["text"]


@pytest.mark.asyncio
async def test_macro_trend_requires_trends():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="x")
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post(
                "/insights",
                json={"mode": "macro_trend", "period": "week", "range_label": "X"},
            )
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 422


@pytest.mark.asyncio
async def test_macro_trend_rejects_empty_trends():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="x")
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post(
                "/insights",
                json={"mode": "macro_trend", "period": "week",
                      "range_label": "X", "trends": {}},
            )
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 422


def test_macro_trend_prompt_uses_friendly_metric_names():
    from server.models import InsightRequest
    from server.routers.insights import _format_macro_trend

    req = InsightRequest(**_MACRO_TREND_PAYLOAD)
    text = _format_macro_trend(req)

    assert "Inner Noise" in text                     # not "pip"
    assert "JUL 27 – AUG 2" in text
    assert "5 of 7" in text
    # Stress Balance must not be glossed as a raw LF/HF ratio.
    assert "stress_balance" not in text
    assert "LF/HF" not in text


def test_macro_trend_format_uses_personal_wording_when_baseline_is_personal():
    """A metric with 90 days of the person's own history must be described as
    their own baseline — never softened into a generic 'typical' claim."""
    from server.models import InsightRequest
    from server.routers.insights import _format_macro_trend

    payload = {
        "mode": "macro_trend", "period": "week", "range_label": "X",
        "trends": {
            "pip": {"avg": 52.0, "baseline": 57.0, "baseline_is_personal": True,
                    "delta_pct": 9.0, "days_above": 6, "days_total": 7,
                    "direction": "lower"},
        },
    }
    text = _format_macro_trend(InsightRequest(**payload))
    assert "own baseline" in text.lower()
    assert "typical" not in text.lower()


def test_macro_trend_format_uses_generic_wording_when_baseline_is_not_personal():
    """A new user with too little history for a personal baseline must never
    be told they beat 'their own baseline' — only a generic typical range."""
    from server.models import InsightRequest
    from server.routers.insights import _format_macro_trend

    payload = {
        "mode": "macro_trend", "period": "week", "range_label": "X",
        "trends": {
            "pip": {"avg": 52.0, "baseline": 57.0, "baseline_is_personal": False,
                    "delta_pct": 9.0, "days_above": 6, "days_total": 7,
                    "direction": "lower"},
        },
    }
    text = _format_macro_trend(InsightRequest(**payload))
    assert "typical" in text.lower()
    assert "own baseline" not in text.lower()


def test_macro_trend_format_defaults_to_generic_when_flag_omitted():
    """An older client that omits the flag must not accidentally grant
    personal-history phrasing — the safe default is generic."""
    from server.models import InsightRequest
    from server.routers.insights import _format_macro_trend

    payload = {
        "mode": "macro_trend", "period": "week", "range_label": "X",
        "trends": {
            "pip": {"avg": 52.0, "baseline": 57.0,
                    "delta_pct": 9.0, "days_above": 6, "days_total": 7,
                    "direction": "lower"},
        },
    }
    text = _format_macro_trend(InsightRequest(**payload))
    assert "typical" in text.lower()
    assert "own baseline" not in text.lower()


def test_macro_trend_prompt_does_not_assert_baseline_is_always_personal():
    """The system prompt must not unconditionally tell the model the baseline
    is the person's own history — it may be a generic reference instead, and
    the prompt must say the input distinguishes the two."""
    from server.routers.insights import _MACRO_TREND_SYSTEM_PROMPT as p

    assert "generic" in p.lower()
    assert "typical" in p.lower()
    assert "the person's own baseline, a" not in p, (
        "must not unconditionally assert the baseline is personal"
    )


# Exactly the seven keys ios/Wythin/Metrics/TrackMetricSpec.swift sends
# (`TrackMetrics.all`, in display order). Kept as one fixture so a new Track
# metric that reaches the wire without a macro-trend name is caught here.
_TRACK_TREND_KEYS = ["dc", "rmssd", "rsa", "rcmse", "dfa1", "pip", "stress_balance"]

# The words _MACRO_TREND_SYSTEM_PROMPT forbids the model from using in its
# reply. Handing any of them to the model as a metric's only available name
# forces it to either break the ban or invent a name of its own.
_BANNED_OUTPUT_TOKENS = ["HRV", "RMSSD", "LF/HF", "entropy", "PIP"]


def test_macro_trend_names_avoid_every_banned_token():
    """The real guard: with all seven keys Track actually sends, the formatted
    prompt must contain none of the tokens the system prompt bans, and must
    not reuse 'Vagal Tone' — the app's name for the `dc` card — for any other
    metric on the same screen."""
    from server.models import InsightRequest
    from server.routers.insights import _format_macro_trend

    payload = {
        "mode": "macro_trend", "period": "week", "range_label": "JUL 27 – AUG 2",
        "trends": {
            key: {"avg": 1.0, "baseline": 1.0, "baseline_is_personal": True,
                  "delta_pct": 3.0, "days_above": 4, "days_total": 7,
                  "direction": "higher"}
            for key in _TRACK_TREND_KEYS
        },
    }
    text = _format_macro_trend(InsightRequest(**payload))
    lowered = text.lower()

    for token in _BANNED_OUTPUT_TOKENS:
        assert token.lower() not in lowered, (
            f"{token!r} is banned from the model's output but appears in its input"
        )

    # Every key must resolve to a name, never fall through to the raw key.
    for key in _TRACK_TREND_KEYS:
        assert key not in text, f"{key!r} leaked into the prompt as a raw key"

    # The app's names, matching the card headings the read sits above.
    for name in ["Vagal Tone", "Energy Reserve", "Conscious Breathing",
                 "Adaptive Capacity", "Harmony", "Inner Noise", "Stress Balance"]:
        assert name in text, (
            f"{name!r} is the app's own card heading and must be the name the "
            f"read uses for that metric"
        )

    # 'Vagal Tone' belongs to `dc` alone. Two metrics sharing it would have the
    # read describe one card by another card's name while both are on screen.
    assert lowered.count("vagal tone") == 1


def test_macro_trend_names_do_not_leak_into_live_state():
    """The overlay is macro-trend-only: `live_state` and `activity` keep the
    clinical glosses in `_METRIC_NAMES`, which they were written for."""
    from server.routers.insights import _METRIC_NAMES

    assert "RMSSD" in _METRIC_NAMES["rmssd"]
    assert "entropy" in _METRIC_NAMES["rcmse"]
