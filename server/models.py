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
    start: Optional[float] = None
    end:   Optional[float] = None
    min:   Optional[float] = None
    max:   Optional[float] = None
    mean:  Optional[float] = None
    direction: Optional[str] = None   # "rising" | "falling" | "stable"
    day_mean: Optional[float] = None  # today's average for this metric


class InsightRequest(BaseModel):
    mode: str = "activity"            # "activity" | "live_state"

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
