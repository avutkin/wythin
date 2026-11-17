"""Bounded wire contracts for the installation-scoped Health API."""
from __future__ import annotations

from datetime import datetime
from typing import Annotated, Literal
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import BaseModel, ConfigDict, Field, AwareDatetime, model_validator, field_validator

Finite = Annotated[float, Field(allow_inf_nan=False)]
Nonnegative = Annotated[float, Field(ge=0, allow_inf_nan=False)]
PositiveSequence = Annotated[int, Field(ge=1, le=9223372036854775806)]
Text = Annotated[str, Field(max_length=200)]
Metric = Literal['heart_rate', 'hrv_sdnn', 'active_energy', 'distance_walking_running', 'distance_cycling', 'distance_swimming', 'step_count']
UNITS = {'heart_rate': 'count/min', 'hrv_sdnn': 'ms', 'active_energy': 'kcal', 'distance_walking_running': 'm', 'distance_cycling': 'm', 'distance_swimming': 'm', 'step_count': 'count'}


class WireModel(BaseModel):
    model_config = ConfigDict(extra='forbid', allow_inf_nan=False)


class Enrollment(WireModel):
    pass


class ConnectionRequest(WireModel):
    stream_id: UUID
    cloud_consent: bool
    consent_version: Annotated[str, Field(min_length=1, max_length=40)]


class ConnectionPatch(WireModel):
    cloud_consent: bool
    consent_version: Annotated[str, Field(min_length=1, max_length=40)] | None = None


class Source(WireModel):
    bundle_identifier: Annotated[str, Field(min_length=1, max_length=255)]
    name: Text
    version: Text | None = None
    device_name: Text | None = None
    device_model: Text | None = None
    software_version: Text | None = None


class Interval(WireModel):
    started_at: AwareDatetime
    ended_at: AwareDatetime

    @model_validator(mode='after')
    def chronological(self):
        if self.ended_at < self.started_at:
            raise ValueError('ended_at must be at or after started_at')
        return self


class Event(Interval):
    kind: Text


class Segment(Interval):
    activity_code: Annotated[int, Field(ge=0)]


class Workout(Interval):
    activity_code: Annotated[int, Field(ge=0)]
    activity_name: Text | None = None
    active_duration_seconds: Nonnegative
    source: Source
    timezone: Annotated[str, Field(max_length=100)] | None = None
    energy_kcal: Nonnegative | None = None
    distance_meters: Nonnegative | None = None
    user_entered: bool = False
    events: Annotated[list[Event], Field(max_length=2000)] = []
    segments: Annotated[list[Segment], Field(max_length=500)] = []

    @field_validator('timezone')
    @classmethod
    def timezone_known(cls, value):
        if value:
            try:
                ZoneInfo(value)
            except (ZoneInfoNotFoundError, ValueError):
                raise ValueError('timezone must be an IANA timezone')
        return value

    @model_validator(mode='after')
    def duration_fits(self):
        # One second tolerates HealthKit timestamp rounding without a sport-duration cap.
        if self.active_duration_seconds > (self.ended_at-self.started_at).total_seconds()+1:
            raise ValueError('active_duration_seconds exceeds elapsed time')
        for interval in [*self.events, *self.segments]:
            if interval.started_at < self.started_at or interval.ended_at > self.ended_at:
                raise ValueError('event or segment is outside workout')
        return self


class Sample(Interval):
    metric: Metric
    value: Nonnegative
    unit: Text
    source: Source
    representation: Literal['point', 'interval', 'series'] = 'point'
    parent_id: UUID | None = None
    workout_ids: Annotated[list[UUID], Field(max_length=100)] = []

    @model_validator(mode='after')
    def metric_unit(self):
        if self.unit != UNITS[self.metric]:
            raise ValueError('unit does not match metric')
        if len(set(self.workout_ids)) != len(self.workout_ids):
            raise ValueError('duplicate workout_ids')
        return self


class SeriesSample(Sample):
    external_id: UUID


class Series(WireModel):
    generation: UUID
    expected_parts: Annotated[int, Field(ge=1, le=10000)] | None = None
    digest: Annotated[str, Field(pattern=r'^[0-9a-f]{64}$')] | None = None
    part_index: Annotated[int, Field(ge=0, le=9999)] | None = None
    samples: Annotated[list[SeriesSample], Field(min_length=1, max_length=1000)] | None = None


class Annotation(WireModel):
    title: Annotated[str, Field(max_length=200)] | None = None
    notes: Annotated[str, Field(max_length=10000)] | None = None


class Statistic(WireModel):
    window: Literal['before', 'during', 'after']
    metric: Metric
    source: Source
    method: Text
    count: Annotated[int, Field(ge=0)]
    mean: Finite | None = None
    minimum: Finite | None = None
    maximum: Finite | None = None
    total: Finite | None = None
    first_at: AwareDatetime | None = None
    last_at: AwareDatetime | None = None
    observed_seconds: Nonnegative = 0
    boundary_samples_omitted: Annotated[int, Field(ge=0)] = 0


class Analysis(WireModel):
    algorithm_version: Annotated[int, Field(ge=1)]
    input_revision: Annotated[int, Field(ge=0)]
    computed_at: AwareDatetime
    status: Literal['pending', 'available', 'partial', 'no_data']
    statistics: Annotated[list[Statistic], Field(max_length=500)] = []
    hrr60: Finite | None = None
    hrr_source: Annotated[str, Field(max_length=255)] | None = None


class Change(WireModel):
    operation_id: UUID
    operation: Literal['upsert_workout', 'delete_workout', 'upsert_sample', 'delete_sample', 'upsert_analysis', 'update_annotation', 'begin_series', 'series_part', 'commit_series']
    external_id: UUID
    workout: Workout | None = None
    sample: Sample | None = None
    analysis: Analysis | None = None
    annotation: Annotation | None = None
    series: Series | None = None

    @model_validator(mode='after')
    def matching_payload(self):
        required = {'upsert_workout':'workout', 'upsert_sample':'sample', 'upsert_analysis':'analysis', 'update_annotation':'annotation', 'begin_series':'series', 'series_part':'series', 'commit_series':'series'}.get(self.operation)
        for key in ('workout', 'sample', 'analysis', 'annotation', 'series'):
            if (getattr(self,key) is not None) != (key == required):
                raise ValueError('operation requires exactly its matching payload')
        if self.series:
            fields = self.series.model_fields_set - {'generation'}
            expected = {'begin_series': {'expected_parts','digest'}, 'series_part': {'part_index','samples'}, 'commit_series': set()}[self.operation]
            if fields != expected or any(getattr(self.series, k) is None for k in expected):
                raise ValueError('invalid fields for series operation')
            if self.series.samples:
                ids = [s.external_id for s in self.series.samples]
                if len(ids) != len(set(ids)) or self.external_id in ids:
                    raise ValueError('series children must have unique IDs distinct from parent')
                if any(s.parent_id != self.external_id for s in self.series.samples):
                    raise ValueError('series sample parent_id must equal external_id')
        return self


class Batch(WireModel):
    schema_version: Literal[1]
    connection_id: UUID
    connection_epoch: PositiveSequence
    batch_id: UUID
    stream_id: UUID
    sequence: PositiveSequence
    changes: Annotated[list[Change], Field(min_length=1, max_length=200)]

    @model_validator(mode='after')
    def unique_operations(self):
        ids = [c.operation_id for c in self.changes]
        if len(ids) != len(set(ids)):
            raise ValueError('duplicate operation_id in batch')
        return self
