"""
Pydantic request/response schemas.
"""
from __future__ import annotations

from datetime import datetime
from typing import Optional
from pydantic import BaseModel, Field
import uuid


class SampleSchema(BaseModel):
    ts:         str           # ISO8601
    mean_bpm:   Optional[float] = None
    rmssd:      Optional[float] = None
    sdnn:       Optional[float] = None
    pnn50:      Optional[float] = None
    lf_hf:      Optional[float] = None
    rsa_ms:     Optional[float] = None
    rsa_idx:    Optional[float] = None
    coherence:  Optional[float] = None
    cbi:        Optional[float] = None
    breath_bpm: Optional[float] = None


class SessionSchema(BaseModel):
    id:                str   = Field(default_factory=lambda: str(uuid.uuid4()))
    started_at:        str
    ended_at:          Optional[str]   = None
    avg_rsa_ms:        Optional[float] = None
    avg_coherence:     Optional[float] = None
    notes:             Optional[str]   = None
    samples:           list[SampleSchema] = []


class ActivitySchema(BaseModel):
    """One logged activity uploaded from the iOS ActivityLog. Metric fields are
    the stored before/during/after window averages (same grid the app shows)."""
    id:               str   = Field(default_factory=lambda: str(uuid.uuid4()))
    activity_type:    str
    activity_subtype: Optional[str] = None
    custom_name:      Optional[str] = None
    started_at:       str
    ended_at:         Optional[str] = None
    is_manual:        bool = False
    impact_score:     Optional[int] = None
    impact_delta_pct: Optional[float] = None
    notes:            Optional[str] = None

    before_hr:     Optional[float] = None; during_hr:     Optional[float] = None; after_hr:     Optional[float] = None
    before_rmssd:  Optional[float] = None; during_rmssd:  Optional[float] = None; after_rmssd:  Optional[float] = None
    before_sdnn:   Optional[float] = None; during_sdnn:   Optional[float] = None; after_sdnn:   Optional[float] = None
    before_rsa:    Optional[float] = None; during_rsa:    Optional[float] = None; after_rsa:    Optional[float] = None
    before_vti:    Optional[float] = None; during_vti:    Optional[float] = None; after_vti:    Optional[float] = None
    before_lfhf:   Optional[float] = None; during_lfhf:   Optional[float] = None; after_lfhf:   Optional[float] = None
    before_stress: Optional[float] = None; during_stress: Optional[float] = None; after_stress: Optional[float] = None
    before_rcmse:  Optional[float] = None; during_rcmse:  Optional[float] = None; after_rcmse:  Optional[float] = None
    before_pip:    Optional[float] = None; during_pip:    Optional[float] = None; after_pip:    Optional[float] = None
    before_dc:     Optional[float] = None; during_dc:     Optional[float] = None; after_dc:     Optional[float] = None
    before_dfa1:   Optional[float] = None; during_dfa1:   Optional[float] = None; after_dfa1:   Optional[float] = None


class MetricSample(BaseModel):
    ts: str
    mean_bpm: Optional[float] = None
    rmssd: Optional[float] = None
    sdnn: Optional[float] = None
    pnn50: Optional[float] = None
    lf_hf: Optional[float] = None
    rsa_ms: Optional[float] = None
    coherence: Optional[float] = None
    cbi: Optional[float] = None
    breath_bpm: Optional[float] = None
    dfa1: Optional[float] = None
    rcmse: Optional[float] = None
    pip: Optional[float] = None
    dc: Optional[float] = None
    vti: Optional[float] = None


class MetricsUpload(BaseModel):
    samples: list[MetricSample]


class ProfileUpload(BaseModel):
    first_name: Optional[str] = None
    last_name:  Optional[str] = None
    phone:      Optional[str] = None
    email:      Optional[str] = None
    age_range:  Optional[str] = None
    gender:     Optional[str] = None
    height_cm:  Optional[int] = None
    weight_kg:  Optional[int] = None
    goals:      list[str] = []
    practices:  list[str] = []
    devices:    list[str] = []
    # Self-reported onboarding baseline, 0-10 each; None where skipped. Every
    # field is optional so an older client that omits them still validates.
    state_focus:         Optional[int] = None
    state_anxiety:       Optional[int] = None
    state_energy:        Optional[int] = None
    state_sleep_quality: Optional[int] = None
    state_stress:        Optional[int] = None
    # Data-sharing consent. Defaults are False, not None: an older client that
    # omits these has not consented to anything, and absence must never be read
    # as agreement.
    consent_share_team:  bool = False
    consent_ai_insights: bool = False


class UsageEvent(BaseModel):
    client_event_id: str
    event_type:      str            # 'foreground' | 'ecg_recording'
    ts:              str            # ISO8601 — start of the interval
    duration_ms:     Optional[int] = None


class UsageUpload(BaseModel):
    events: list[UsageEvent] = []


class UploadResponse(BaseModel):
    id: str


class SessionListItem(BaseModel):
    id:            str
    started_at:    str
    ended_at:      Optional[str]
    avg_rsa_ms:    Optional[float]
    avg_coherence: Optional[float]


class TickPayload(BaseModel):
    user_id:   str
    ts:        str
    mean_bpm:  Optional[float] = None
    rmssd:     Optional[float] = None
    rsa_ms:    Optional[float] = None
    coherence: Optional[float] = None
    cbi:       Optional[float] = None
    breath_bpm: Optional[float] = None


class AdminUserRow(BaseModel):
    id:          str
    device_id:   Optional[str]
    last_seen:   Optional[str]
    session_count: int


class MetricTrend(BaseModel):
    # Legacy fields, kept optional so an older client build still validates.
    start: Optional[float] = None
    end:   Optional[float] = None
    mean:  Optional[float] = None
    direction: Optional[str] = None
    day_mean: Optional[float] = None

    # Current shape: the arc of the window rather than two endpoints.
    now:        Optional[float] = None
    min:        Optional[float] = None
    max:        Optional[float] = None
    buckets:    Optional[list[float]] = None   # 5 x 2-min means, oldest first
    slope_pct:  Optional[float] = None
    volatility: Optional[str] = None           # "low" | "moderate" | "high"
    shape:      Optional[str] = None


class MetricComponent(BaseModel):
    z: Optional[float] = None
    level: Optional[str] = None


class MacroTrend(BaseModel):
    """One metric's summary over a Track period. All values are computed
    on-device; the model receives them and supplies language only."""
    avg:        float
    baseline:   Optional[float] = None
    # Whether `baseline` is this person's own 90-day median, versus a fixed
    # physiological norm used when they don't yet have enough history.
    # Optional so an older client that omits it still validates.
    baseline_is_personal: Optional[bool] = None
    # Benefit-signed: positive always means improvement, including for metrics
    # where the raw value fell (Inner Noise, Stress Balance).
    delta_pct:  Optional[float] = None
    days_above: Optional[int] = None
    days_total: Optional[int] = None
    direction:  Optional[str] = None


class SleepStageMinutes(BaseModel):
    """Minutes in each stage. Cut at typical adult shares upstream, so these
    are the night's SHAPE and must not be read as a clinical hypnogram."""
    wake: Optional[int] = None
    rem:  Optional[int] = None
    n1:   Optional[int] = None
    n2:   Optional[int] = None
    n3:   Optional[int] = None


class SleepPositionShare(BaseModel):
    """How long the body held one orientation, over the whole night."""
    position: str            # "Supine" | "Prone" | "Left side" | "Right side" | "Upright"
    minutes:  int


class SleepArc(BaseModel):
    """One metric's first half against its second half.

    A night average is a single number for eight hours and hides the only
    thing worth acting on: whether recovery arrived, and WHEN. The halves are
    the smallest honest way to carry that.
    """
    first_half:  Optional[float] = None
    second_half: Optional[float] = None
    night_avg:   Optional[float] = None


class SleepNight(BaseModel):
    """One measured night. Every number is computed on-device; the model
    receives them and supplies language only."""
    bedtime:     Optional[str] = None     # "22:05" local
    wake_time:   Optional[str] = None     # "07:30" local
    in_bed_min:  Optional[int] = None
    asleep_min:  Optional[int] = None
    score:       Optional[int] = None
    # Section name -> 0-100, as the SECTIONS card shows them.
    section_scores: Optional[dict[str, int]] = None
    stages:      Optional[SleepStageMinutes] = None
    wake_bouts:      Optional[int] = None
    longest_wake_min: Optional[int] = None
    # Sleep Regularity Index, 0-100 — how alike this night's timing is to the
    # nights before it.
    regularity:  Optional[float] = None
    # Absent on nights recorded before orientation was stored at all. False
    # means "the sensor never recorded it", NOT "the person never moved" —
    # the two must never be described alike.
    position_recorded: bool = False
    positions:   Optional[list[SleepPositionShare]] = None
    arcs:        Optional[dict[str, SleepArc]] = None
    breath_bpm:  Optional[float] = None
    lowest_hr:    Optional[float] = None
    lowest_hr_at: Optional[str] = None    # "03:40" local


class InsightRequest(BaseModel):
    mode: str = "activity"            # "activity" | "live_state" | "day_potential" | "macro_trend" | "sleep"

    # "activity" mode fields
    activity_type:    Optional[str] = None
    activity_subtype: Optional[str] = None
    duration_min:     Optional[int] = None
    before_hr:    Optional[float] = None
    during_hr:    Optional[float] = None
    after_hr:     Optional[float] = None
    before_rsa:   Optional[float] = None
    during_rsa:   Optional[float] = None
    after_rsa:    Optional[float] = None
    before_sdnn:  Optional[float] = None
    during_sdnn:  Optional[float] = None
    after_sdnn:   Optional[float] = None
    before_lf_hf: Optional[float] = None
    during_lf_hf: Optional[float] = None
    after_lf_hf:  Optional[float] = None
    # The rest of what the session detail charts. Optional like everything
    # else here, so a client that predates them still gets a read — it just
    # gets a thinner one. See `_ACTIVITY_METRICS` in routers/insights.py.
    before_rmssd:  Optional[float] = None; during_rmssd:  Optional[float] = None; after_rmssd:  Optional[float] = None
    before_dc:     Optional[float] = None; during_dc:     Optional[float] = None; after_dc:     Optional[float] = None
    before_rcmse:  Optional[float] = None; during_rcmse:  Optional[float] = None; after_rcmse:  Optional[float] = None
    before_pip:    Optional[float] = None; during_pip:    Optional[float] = None; after_pip:    Optional[float] = None
    before_dfa1:   Optional[float] = None; during_dfa1:   Optional[float] = None; after_dfa1:   Optional[float] = None
    before_stress: Optional[float] = None; during_stress: Optional[float] = None; after_stress: Optional[float] = None

    # "live_state" mode fields
    window_minutes: Optional[int] = None
    metrics: Optional[dict[str, MetricTrend]] = None

    # "day_potential" mode fields. The score and band are computed on-device;
    # the model receives them and supplies language only.
    score:      Optional[int] = None
    band:       Optional[str] = None
    anchor_hour:         Optional[float] = None
    anchor_duration_min: Optional[int] = None
    late:       Optional[bool] = None
    confidence: Optional[str] = None
    components: Optional[dict[str, MetricComponent]] = None
    modifiers:  Optional[dict[str, float]] = None
    baseline_anchors:    Optional[int] = None
    baseline_target:     Optional[int] = None
    baseline_sufficient: Optional[bool] = None
    # A score exists but the range is still forming. Distinct from
    # `not baseline_sufficient`, which also covers the very first morning —
    # where there is no reference day at all and so no score.
    provisional:         Optional[bool] = None
    recent:     Optional[list[int]] = None
    streak_current: Optional[int] = None
    streak_best:    Optional[int] = None
    grace_used:     Optional[bool] = None

    # "macro_trend" mode fields
    period:      Optional[str] = None    # "week" | "month" | "six_month"
    range_label: Optional[str] = None
    trends:      Optional[dict[str, MacroTrend]] = None

    # "sleep" mode fields
    sleep: Optional[SleepNight] = None


class InsightResponse(BaseModel):
    text: str


class TokenCreate(BaseModel):
    name: Optional[str] = None


class TokenCreated(BaseModel):
    token: str            # raw token — returned once
    id: str
    name: Optional[str] = None
    created_at: str


class TokenInfo(BaseModel):
    id: str
    name: Optional[str] = None
    created_at: str
    last_used_at: Optional[str] = None
