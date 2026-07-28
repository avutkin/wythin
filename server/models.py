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


class InsightRequest(BaseModel):
    mode: str = "activity"            # "activity" | "live_state" | "day_potential"

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
