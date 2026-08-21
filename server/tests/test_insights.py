"""
Tests for POST /insights — the OpenAI client is swapped for a fake via
FastAPI's dependency_overrides, so no real API calls are made.
"""
from __future__ import annotations

import pytest
from httpx import AsyncClient, ASGITransport
from openai import OpenAIError

from server.main import app
from server.routers.insights import get_openai_client, require_ai_consent


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
    app.dependency_overrides[require_ai_consent] = lambda: "consented-device"
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(
        content="  Solid session — your RSA improved nicely.  "
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
        app.dependency_overrides.pop(require_ai_consent, None)

    assert r.status_code == 200
    assert r.json()["text"] == "Solid session — your RSA improved nicely."


@pytest.mark.asyncio
async def test_generate_insight_openai_error_returns_502():
    app.dependency_overrides[require_ai_consent] = lambda: "consented-device"
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(raise_error=True)
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
        app.dependency_overrides.pop(require_ai_consent, None)

    assert r.status_code == 502


@pytest.mark.asyncio
async def test_generate_insight_empty_response_returns_502():
    app.dependency_overrides[require_ai_consent] = lambda: "consented-device"
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="")
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
        app.dependency_overrides.pop(require_ai_consent, None)

    assert r.status_code == 502


def test_get_openai_client_requires_api_key(monkeypatch):
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    with pytest.raises(RuntimeError):
        get_openai_client()


@pytest.mark.asyncio
async def test_generate_live_state_insight_success():
    app.dependency_overrides[require_ai_consent] = lambda: "consented-device"
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(
        content="  Your heart rate has been gradually settling over the last 10 minutes.  "
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_LIVE_STATE_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
        app.dependency_overrides.pop(require_ai_consent, None)

    assert r.status_code == 200
    assert r.json()["text"] == "Your heart rate has been gradually settling over the last 10 minutes."


@pytest.mark.asyncio
async def test_generate_live_state_insight_missing_metrics_returns_422():
    app.dependency_overrides[require_ai_consent] = lambda: "consented-device"
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient()
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json={"mode": "live_state", "window_minutes": 10})
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
        app.dependency_overrides.pop(require_ai_consent, None)
    assert r.status_code == 422


@pytest.mark.asyncio
async def test_generate_activity_insight_missing_activity_type_returns_422():
    app.dependency_overrides[require_ai_consent] = lambda: "consented-device"
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient()
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json={"mode": "activity"})
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
        app.dependency_overrides.pop(require_ai_consent, None)
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
    app.dependency_overrides[require_ai_consent] = lambda: "consented-device"
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(
        content="Good Reserves\n• a\n• b\n→ c"
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_DAY_POTENTIAL_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
        app.dependency_overrides.pop(require_ai_consent, None)

    assert r.status_code == 200
    assert r.json()["text"].startswith("Good Reserves")


@pytest.mark.asyncio
async def test_day_potential_requires_score_when_baseline_sufficient():
    payload = {k: v for k, v in _DAY_POTENTIAL_PAYLOAD.items() if k != "score"}
    app.dependency_overrides[require_ai_consent] = lambda: "consented-device"
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="x")
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=payload)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
        app.dependency_overrides.pop(require_ai_consent, None)

    assert r.status_code == 422


@pytest.mark.asyncio
async def test_day_potential_allows_recent_when_baseline_insufficient():
    payload = dict(_DAY_POTENTIAL_PAYLOAD)
    payload.pop("score")
    payload["baseline_sufficient"] = False
    payload["baseline_anchors"] = 3
    payload["recent"] = [58, 61, 64]
    app.dependency_overrides[require_ai_consent] = lambda: "consented-device"
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(
        content="Learning\n• a\n• b\n→ c"
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=payload)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
        app.dependency_overrides.pop(require_ai_consent, None)

    assert r.status_code == 200


@pytest.mark.asyncio
async def test_day_potential_rejects_missing_anchor():
    payload = {k: v for k, v in _DAY_POTENTIAL_PAYLOAD.items() if k != "anchor_hour"}
    app.dependency_overrides[require_ai_consent] = lambda: "consented-device"
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="x")
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=payload)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
        app.dependency_overrides.pop(require_ai_consent, None)

    assert r.status_code == 422


@pytest.mark.asyncio
async def test_day_potential_provisional_requires_a_score():
    """A provisional baseline still produces a number — a request claiming one
    without a score is malformed."""
    payload = {k: v for k, v in _DAY_POTENTIAL_PAYLOAD.items() if k != "score"}
    payload["baseline_sufficient"] = False
    payload["provisional"] = True
    payload["baseline_anchors"] = 3
    app.dependency_overrides[require_ai_consent] = lambda: "consented-device"
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="x")
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=payload)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
        app.dependency_overrides.pop(require_ai_consent, None)

    assert r.status_code == 422


@pytest.mark.asyncio
async def test_day_potential_provisional_with_a_score_succeeds():
    payload = dict(_DAY_POTENTIAL_PAYLOAD)
    payload["baseline_sufficient"] = False
    payload["provisional"] = True
    payload["baseline_anchors"] = 3
    payload["baseline_target"] = 7
    payload["recent"] = [58, 61, 64]
    app.dependency_overrides[require_ai_consent] = lambda: "consented-device"
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(
        content="Early Days\n• a\n• b\n→ c"
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=payload)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
        app.dependency_overrides.pop(require_ai_consent, None)

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
    app.dependency_overrides[require_ai_consent] = lambda: "consented-device"
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(
        content="First One\n• a\n• b\n→ c"
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=payload)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
        app.dependency_overrides.pop(require_ai_consent, None)

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
    app.dependency_overrides[require_ai_consent] = lambda: "consented-device"
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(
        content="• Vagal tone held **steady** all week.\n→ Keep the evening breathing."
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_MACRO_TREND_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
        app.dependency_overrides.pop(require_ai_consent, None)

    assert r.status_code == 200
    text = r.json()["text"]
    assert "•" in text
    assert "→" in text


@pytest.mark.asyncio
async def test_macro_trend_requires_trends():
    app.dependency_overrides[require_ai_consent] = lambda: "consented-device"
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="x")
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post(
                "/insights",
                json={"mode": "macro_trend", "period": "week", "range_label": "X"},
            )
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
        app.dependency_overrides.pop(require_ai_consent, None)

    assert r.status_code == 422


@pytest.mark.asyncio
async def test_macro_trend_rejects_empty_trends():
    app.dependency_overrides[require_ai_consent] = lambda: "consented-device"
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
        app.dependency_overrides.pop(require_ai_consent, None)

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


def test_macro_trend_prompt_specifies_bulleted_structure_capped_at_three():
    """The rewritten prompt (bullets for what the period shows, arrows for
    what to do next) replaces the old 'two sentences' shape. Pin the actual
    constraints the model is given, not just that SOME text is present —
    a prompt that dropped the cap, or that stopped asking for bullets at all,
    must fail this."""
    from server.routers.insights import _MACRO_TREND_SYSTEM_PROMPT as p

    lowered = p.lower()
    # Bulleted reads for what the period shows, capped at three.
    assert "•" in p
    assert "at most three" in lowered
    # Actions still use '→', same character the old shape used.
    assert "→" in p
    # No leftover instruction to write prose sentences — the old shape must
    # actually be gone, not just supplemented.
    assert "two sentences" not in lowered
    # The old unconditional "no markdown" ban must be gone too — bold spans
    # are markdown, and now explicitly allowed.
    assert "no markdown, no" not in lowered


def test_macro_trend_prompt_matches_live_state_bold_bullet_convention():
    """The user's ask: the macro read's bullets should follow the SAME bold-
    span convention `_LIVE_STATE_SYSTEM_PROMPT` already defines for its own
    bullets, so the two surfaces read as one system rather than two prompts
    that happen to both use '•'. Pin the shared phrase rather than merely
    'both mention bold' — two independently-worded bold instructions would
    still pass a looser check."""
    from server.routers.insights import (
        _MACRO_TREND_SYSTEM_PROMPT as macro,
        _LIVE_STATE_SYSTEM_PROMPT as live,
    )

    shared = "the takeaway, exactly one short bold span per bullet"
    assert shared in live
    assert shared in macro


def test_macro_trend_prompt_keeps_delta_sign_and_banned_token_rules():
    """The restructuring must not have dropped the two load-bearing
    correctness rules while rewriting the reply shape around it."""
    from server.routers.insights import _MACRO_TREND_SYSTEM_PROMPT as p

    assert "benefit-signed" in p
    assert "never describe it as a rise" in p
    for token in _BANNED_OUTPUT_TOKENS:
        assert token in p, f"{token!r} must still be named as a banned word"


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
    for name in ["Vagal Tone", "Calm Power", "Conscious Breathing",
                 "Adaptive Capacity", "Harmony", "Inner Noise", "Stress Balance"]:
        assert name in text, (
            f"{name!r} is the app's own card heading and must be the name the "
            f"read uses for that metric"
        )

    # 'Vagal Tone' belongs to `dc` alone. Two metrics sharing it would have the
    # read describe one card by another card's name while both are on screen.
    assert lowered.count("vagal tone") == 1


def test_macro_trend_format_uses_month_period_label_and_days_unit():
    """The `month` branch of `_PERIOD_LABELS` and `unit` are only exercised by
    the `week` fixture elsewhere in this file — pin `month` directly."""
    from server.models import InsightRequest
    from server.routers.insights import _format_macro_trend

    payload = {
        "mode": "macro_trend", "period": "month", "range_label": "JULY 2026",
        "trends": {
            "pip": {"avg": 52.0, "baseline": 57.0, "baseline_is_personal": True,
                    "delta_pct": 9.0, "days_above": 20, "days_total": 28,
                    "direction": "lower"},
        },
    }
    text = _format_macro_trend(InsightRequest(**payload))
    assert "this month" in text
    assert "days in the period" in text
    assert "20 of 28 days better than" in text
    assert "months" not in text


def test_macro_trend_format_uses_six_month_period_label_and_months_unit():
    """The `six_month` branch: unlike `week`/`month`, its unit word is
    "months" in both the header sentence and the days_above line."""
    from server.models import InsightRequest
    from server.routers.insights import _format_macro_trend

    payload = {
        "mode": "macro_trend", "period": "six_month", "range_label": "FEB – JUL 2026",
        "trends": {
            "pip": {"avg": 52.0, "baseline": 57.0, "baseline_is_personal": True,
                    "delta_pct": 9.0, "days_above": 4, "days_total": 6,
                    "direction": "lower"},
        },
    }
    text = _format_macro_trend(InsightRequest(**payload))
    assert "these six months" in text
    assert "months in the period" in text
    assert "4 of 6 months better than" in text


def test_macro_trend_names_do_not_leak_into_live_state():
    """The overlay is macro-trend-only: `live_state` and `activity` keep the
    clinical glosses in `_METRIC_NAMES`, which they were written for."""
    from server.routers.insights import _METRIC_NAMES

    assert "RMSSD" in _METRIC_NAMES["rmssd"]
    assert "entropy" in _METRIC_NAMES["rcmse"]


# ── Consent gate ──────────────────────────────────────────────────────────
#
# These exercise `require_ai_consent` for real against the database, rather than
# overriding it — the point of the gate is that it reads a stored answer, so a
# test that stubs the read tests nothing.

from contextlib import asynccontextmanager  # noqa: E402


@asynccontextmanager
async def _db_client():
    from server.db import init_pool, close_pool, create_schema
    await init_pool()
    await create_schema()
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            yield c
    finally:
        await close_pool()


_CONSENT_PROFILE = {
    "phone": "+15550000000",
    "email": "consent@example.com",
    "goals": ["Reduce anxiety"],
    "practices": ["Breathwork"],
    "devices": ["Polar H10"],
}


@pytest.mark.asyncio
async def test_insights_refused_without_user_header():
    """No identity means no checkable consent, which must resolve to refusal."""
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="should not be reached")
    try:
        async with _db_client() as c:
            r = await c.post("/insights", json=_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 403


@pytest.mark.asyncio
async def test_insights_refused_for_unknown_device():
    """A device with no profile row has not answered the question."""
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="should not be reached")
    try:
        async with _db_client() as c:
            r = await c.post("/insights", json=_PAYLOAD,
                             headers={"X-User-ID": "never-onboarded-device"})
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 403


@pytest.mark.asyncio
async def test_insights_refused_when_consent_is_false():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="should not be reached")
    try:
        async with _db_client() as c:
            await c.post("/v1/profile",
                         json={**_CONSENT_PROFILE, "consent_ai_insights": False},
                         headers={"X-User-ID": "gate-declined"})
            r = await c.post("/insights", json=_PAYLOAD,
                             headers={"X-User-ID": "gate-declined"})
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 403


@pytest.mark.asyncio
async def test_insights_allowed_when_consent_is_true():
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="Nice work.")
    try:
        async with _db_client() as c:
            await c.post("/v1/profile",
                         json={**_CONSENT_PROFILE, "consent_ai_insights": True},
                         headers={"X-User-ID": "gate-allowed"})
            r = await c.post("/insights", json=_PAYLOAD,
                             headers={"X-User-ID": "gate-allowed"})
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 200
    assert r.json()["text"] == "Nice work."


@pytest.mark.asyncio
async def test_withdrawing_consent_takes_effect_immediately():
    """Turning the switch off must stop the next call, not the next release."""
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="Nice work.")
    try:
        async with _db_client() as c:
            await c.post("/v1/profile",
                         json={**_CONSENT_PROFILE, "consent_ai_insights": True},
                         headers={"X-User-ID": "gate-withdrawn"})
            first = await c.post("/insights", json=_PAYLOAD,
                                 headers={"X-User-ID": "gate-withdrawn"})
            await c.post("/v1/profile",
                         json={**_CONSENT_PROFILE, "consent_ai_insights": False},
                         headers={"X-User-ID": "gate-withdrawn"})
            second = await c.post("/insights", json=_PAYLOAD,
                                  headers={"X-User-ID": "gate-withdrawn"})
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert first.status_code == 200
    assert second.status_code == 403


@pytest.mark.asyncio
async def test_profile_omitting_consent_is_treated_as_no():
    """An older client that doesn't send the field has not consented."""
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="should not be reached")
    try:
        async with _db_client() as c:
            await c.post("/v1/profile", json=_CONSENT_PROFILE,
                         headers={"X-User-ID": "gate-legacy-client"})
            r = await c.post("/insights", json=_PAYLOAD,
                             headers={"X-User-ID": "gate-legacy-client"})
    finally:
        app.dependency_overrides.pop(get_openai_client, None)

    assert r.status_code == 403


# ---------------------------------------------------------------------------
# The session read names the metrics the session screen shows
# ---------------------------------------------------------------------------

_FULL_ACTIVITY_PAYLOAD = {
    "activity_type": "Breathwork",
    "activity_subtype": "Breath Hold",
    "duration_min": 5,
    "before_hr": 83.0,     "during_hr": 82.0,     "after_hr": 82.0,
    "before_rmssd": 34.0,  "during_rmssd": 41.0,  "after_rmssd": 38.0,
    "before_rsa": 24.0,    "during_rsa": 47.0,    "after_rsa": 30.0,
    "before_dc": 6.1,      "during_dc": 8.4,      "after_dc": 7.0,
    "before_rcmse": 1.3,   "during_rcmse": 1.5,   "after_rcmse": 1.4,
    "before_pip": 57.0,    "during_pip": 51.0,    "after_pip": 54.0,
    "before_dfa1": 0.88,   "during_dfa1": 0.97,   "after_dfa1": 0.93,
    "before_stress": 55.0, "during_stress": 44.0, "after_stress": 48.0,
    "before_sdnn": 46.0,   "during_sdnn": 58.0,   "after_sdnn": 50.0,
}


def test_activity_format_names_every_metric_the_session_screen_charts():
    """The read is printed directly beneath those charts. A read built from a
    four-metric subset described a session the person could not see."""
    from server.models import InsightRequest
    from server.routers.insights import _format_metrics

    text = _format_metrics(InsightRequest(**_FULL_ACTIVITY_PAYLOAD))
    for name in ["Vagal Tone", "Adaptive Capacity", "Inner Noise", "Harmony",
                 "Stress Balance", "Conscious Breathing", "Calm Power", "Pulse"]:
        assert name in text, f"{name!r} is charted on the session screen but not in the read's input"


def test_activity_format_hands_the_model_no_name_the_screen_lacks():
    """Every metric arrives under its consumer name, never as the raw
    abbreviation — the model can only say back what it was given, and the
    reply that prompted this said 'RSA and SDNN increased' and cited an
    'LF/HF ratio' under a screen carrying none of those three words."""
    from server.models import InsightRequest
    from server.routers.insights import _format_metrics

    text = _format_metrics(InsightRequest(**_FULL_ACTIVITY_PAYLOAD))
    for token in ["RMSSD", "SDNN", "LF/HF", "HRV", "RSA:", "DFA", "PIP"]:
        assert token not in text, f"{token!r} is not a name the app shows anywhere"


def test_activity_format_never_feeds_the_raw_lf_hf_ratio():
    """LF/HF rises during slow paced breathing — the vagal peak moves out of
    HF into LF — so a coach handed it reads the calmest thing a person can do
    as sympathetic activation. Stress Balance is what the app uses instead."""
    from server.models import InsightRequest
    from server.routers.insights import _format_metrics

    payload = dict(_FULL_ACTIVITY_PAYLOAD)
    payload.update({"before_lf_hf": 0.7, "during_lf_hf": 4.2, "after_lf_hf": 1.1})
    text = _format_metrics(InsightRequest(**payload))
    assert "4.2" not in text
    assert "Stress Balance" in text


def test_activity_format_skips_metrics_the_client_did_not_send():
    """An older build sends a subset. It gets a thinner read, not a read full
    of `None`s."""
    from server.models import InsightRequest
    from server.routers.insights import _format_metrics

    text = _format_metrics(InsightRequest(**_PAYLOAD))
    assert "Conscious Breathing" in text
    assert "Calm Power" not in text
    assert "None" not in text


def test_activity_prompt_forbids_the_abbreviations_the_screen_never_shows():
    """The macro-trend read has carried this rule since it shipped; the
    session read had none, which is why its text spoke a vocabulary that
    appears on no screen in the app."""
    from server.routers.insights import _SYSTEM_PROMPT

    for token in ["HRV", "RMSSD", "SDNN", "LF/HF", "PIP"]:
        assert token in _SYSTEM_PROMPT, f"{token!r} must be named as forbidden"
    assert "Calm Power" in _SYSTEM_PROMPT


# --- sleep mode -------------------------------------------------------------

_SLEEP_PAYLOAD = {
    "mode": "sleep",
    "sleep": {
        "bedtime": "22:05",
        "wake_time": "07:30",
        "in_bed_min": 565,
        "asleep_min": 400,
        "score": 71,
        "section_scores": {"Timing": 82, "Duration": 74, "Continuity": 48,
                           "Autonomic": 80, "Breathing": 66},
        "stages": {"wake": 165, "rem": 80, "n1": 14, "n2": 275, "n3": 31},
        "wake_bouts": 7,
        "longest_wake_min": 38,
        "regularity": 74.0,
        "position_recorded": True,
        "positions": [{"position": "Supine", "minutes": 250},
                      {"position": "Left side", "minutes": 96},
                      {"position": "Right side", "minutes": 54}],
        "arcs": {
            "dc":    {"first_half": 6.1,  "second_half": 8.4,  "night_avg": 7.2},
            "rmssd": {"first_half": 34.0, "second_half": 44.0, "night_avg": 39.1},
            "hr":    {"first_half": 60.0, "second_half": 56.0, "night_avg": 58.0},
            "pip":   {"first_half": 41.0, "second_half": 33.0, "night_avg": 37.0},
        },
        "breath_bpm": 13.4,
        "lowest_hr": 49.0,
        "lowest_hr_at": "03:40",
    },
}


@pytest.mark.asyncio
async def test_sleep_success():
    app.dependency_overrides[require_ai_consent] = lambda: "consented-device"
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(
        content="  A broken night that still recovered\n"
                "• Recovery **arrived late**.\n"
                "→ Hold a fixed wake time this week.  "
    )
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json=_SLEEP_PAYLOAD)
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
        app.dependency_overrides.pop(require_ai_consent, None)

    assert r.status_code == 200
    text = r.json()["text"]
    assert text.startswith("A broken night")     # stripped
    assert "→" in text


@pytest.mark.asyncio
async def test_sleep_requires_a_night():
    app.dependency_overrides[require_ai_consent] = lambda: "consented-device"
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="x")
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights", json={"mode": "sleep"})
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
        app.dependency_overrides.pop(require_ai_consent, None)

    assert r.status_code == 422


@pytest.mark.asyncio
async def test_sleep_requires_time_asleep():
    """A night with no asleep minutes is not a night to interpret — refuse it
    rather than invite the model to narrate an empty window."""
    app.dependency_overrides[require_ai_consent] = lambda: "consented-device"
    app.dependency_overrides[get_openai_client] = lambda: _FakeOpenAIClient(content="x")
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            r = await client.post("/insights",
                                  json={"mode": "sleep", "sleep": {"bedtime": "22:05"}})
    finally:
        app.dependency_overrides.pop(get_openai_client, None)
        app.dependency_overrides.pop(require_ai_consent, None)

    assert r.status_code == 422


def test_sleep_format_carries_the_night_shape():
    from server.models import InsightRequest
    from server.routers.insights import _format_sleep

    text = _format_sleep(InsightRequest(**_SLEEP_PAYLOAD))

    assert "22:05" in text and "07:30" in text
    assert "6h 40m asleep" in text          # 400 min, in the unit the app shows
    assert "9h 25m in bed" in text          # 565 min
    assert "71%" in text                    # efficiency, derived not invented
    assert "7 wake bouts" in text
    assert "longest 38m" in text
    assert "Continuity 48" in text


def test_sleep_format_uses_screen_names_not_abbreviations():
    """The read is printed under the very charts these metrics come from, so a
    name the person cannot find on that screen describes someone else's night."""
    from server.models import InsightRequest
    from server.routers.insights import _format_sleep

    text = _format_sleep(InsightRequest(**_SLEEP_PAYLOAD))

    assert "Vagal Tone" in text
    assert "Calm Power" in text
    assert "Inner Noise" in text
    assert "Pulse" in text
    for banned in ("RMSSD", "HRV", "PIP", "DFA", "entropy"):
        assert banned not in text, banned


def test_sleep_format_reports_the_arc_not_just_the_average():
    from server.models import InsightRequest
    from server.routers.insights import _format_sleep

    text = _format_sleep(InsightRequest(**_SLEEP_PAYLOAD))

    assert "first half" in text and "second half" in text
    assert "34.0" in text and "44.0" in text


def test_sleep_format_reports_supine_share():
    from server.models import InsightRequest
    from server.routers.insights import _format_sleep

    text = _format_sleep(InsightRequest(**_SLEEP_PAYLOAD))

    assert "Supine" in text
    assert "250m" in text
    # 250 of 400 asleep minutes
    assert "63%" in text


def test_sleep_format_states_position_was_not_recorded_rather_than_omitting_it():
    """Silence reads as 'the person never lay on their back'. A night that
    predates orientation storage has to say so, or the model will fill the
    gap with a claim the sensor never made."""
    from server.models import InsightRequest
    from server.routers.insights import _format_sleep

    payload = {"mode": "sleep", "sleep": dict(_SLEEP_PAYLOAD["sleep"])}
    payload["sleep"].pop("positions")
    payload["sleep"]["position_recorded"] = False

    text = _format_sleep(InsightRequest(**payload))

    assert "not recorded" in text.lower()
    assert "Supine" not in text


def test_sleep_prompt_forbids_diagnosis_and_stage_precision():
    from server.routers.insights import _SLEEP_SYSTEM_PROMPT

    low = _SLEEP_SYSTEM_PROMPT.lower()
    assert "apnea" in low          # named, in order to be forbidden
    assert "diagnos" in low
    assert "shape" in low          # stage minutes are a shape, not a hypnogram


def test_sleep_prompt_specifies_bullets_and_recommendations():
    from server.routers.insights import _SLEEP_SYSTEM_PROMPT

    assert "•" in _SLEEP_SYSTEM_PROMPT
    assert "→" in _SLEEP_SYSTEM_PROMPT
    assert "**" in _SLEEP_SYSTEM_PROMPT      # same bold convention as the other reads


def test_sleep_prompt_names_avoid_every_banned_token():
    """Same rule the macro read is held to: a banned word must not reach the
    model as a metric's only available name."""
    from server.routers.insights import _SLEEP_METRIC_NAMES

    for key, label in _SLEEP_METRIC_NAMES.items():
        for banned in ("HRV", "RMSSD", "LF/HF", "entropy", "PIP"):
            assert banned not in label, (key, banned)
    # "Vagal Tone" is the app's name for `dc` and for nothing else.
    assert sum("Vagal Tone" in v for v in _SLEEP_METRIC_NAMES.values()) == 1
