"""Versioned signal audit, not a mood classifier or clinical NN analysis.

The source packet remains authoritative. RR ticks retain 1/1024 s precision;
receipt timestamps are not advertised as beat timestamps. No interpolation.
"""
from __future__ import annotations
import base64
import binascii
import json
import math
import statistics
import struct
import uuid

VERSION = 'signal-audit-v1'


def decode_notification(stream: str, data: bytes) -> dict:
    if stream in ('ecg', 'acc'):
        width, kind, frame = (3, 0, 0) if stream == 'ecg' else (6, 2, 1)
        if len(data) <= 10 or data[0] != kind or data[9] != frame or (len(data) - 10) % width:
            raise ValueError('unsupported or malformed PMD frame')
        samples = ([int.from_bytes(data[i:i+3], 'little', signed=True) for i in range(10, len(data), 3)]
                   if stream == 'ecg' else list(struct.iter_unpack('<hhh', data[10:])))
        return {'device_timestamp_ns': int.from_bytes(data[1:9], 'little'), 'samples': samples}
    if stream != 'hr' or len(data) < 2:
        raise ValueError('unsupported or malformed notification')
    flags = data[0]
    offset = 3 if flags & 1 else 2
    if len(data) < offset:
        raise ValueError('truncated heart rate')
    bpm = int.from_bytes(data[1:offset], 'little')
    if flags & 8:
        offset += 2
    if len(data) < offset or (len(data) - offset) % 2 or (not flags & 16 and len(data) != offset):
        raise ValueError('truncated heart-rate fields')
    ticks = [v[0] for v in struct.iter_unpack('<H', data[offset:])] if flags & 16 else []
    return {'bpm': bpm, 'contact': bool(flags & 2) if flags & 4 else None,
            'rr_ticks': ticks, 'rr_ms': [x * 1000 / 1024 for x in ticks]}


class Moments:
    def __init__(self):
        self.n, self.mean, self.m2 = 0, 0.0, 0.0
        self.low, self.high = None, None

    def add(self, x):
        self.n += 1
        delta = x - self.mean
        self.mean += delta / self.n
        self.m2 += delta * (x - self.mean)
        self.low = x if self.low is None else min(self.low, x)
        self.high = x if self.high is None else max(self.high, x)

    @property
    def variance(self):
        return max(0, self.m2 / self.n) if self.n else None


def analyze_chunk(payload: bytes) -> dict:
    quality = dict(duplicate_packets=0, unsupported_packets=0, off_body_packets=0,
                   rr_invalid_count=0, hr_receipt_gaps=0, receipt_clock_resets=0)
    counts = dict(ecg=0, acc=0, hr=0)
    ecg, axes, magnitude = Moments(), [Moments(), Moments(), Moments()], Moments()
    rr_ticks, rr_packets, valid_rr, diffs = [], [], [], []
    constant_ecg = 0
    first_at = last_at = prev_hr_at = previous_rr = None
    seen = set()
    for line in payload.splitlines():
        if not line.strip():
            continue
        try:
            record = json.loads(line)
            identifier = str(uuid.UUID(record['id']))
            stream, at = record['stream'], record['receivedAt']
            if stream not in counts or isinstance(at, bool) or not isinstance(at, (int, float)) or not math.isfinite(at):
                raise ValueError('invalid packet metadata')
            data = base64.b64decode(record['payload'], validate=True)
        except (KeyError, TypeError, ValueError, binascii.Error) as exc:
            raise ValueError('invalid raw journal record') from exc
        if identifier in seen:
            quality['duplicate_packets'] += 1
            continue
        seen.add(identifier)
        if last_at is not None and at < last_at:
            quality['receipt_clock_resets'] += 1
            previous_rr = None
        first_at = at if first_at is None else min(first_at, at)
        last_at = at
        counts[stream] += 1
        try:
            decoded = decode_notification(stream, data)
        except ValueError:
            quality['unsupported_packets'] += 1
            if stream == 'hr':
                previous_rr = None
            continue
        if stream == 'ecg':
            constant_ecg += int(len(set(decoded['samples'])) == 1)
            for value in decoded['samples']:
                ecg.add(value)
        elif stream == 'acc':
            for xyz in decoded['samples']:
                for axis, value in zip(axes, xyz):
                    axis.add(value)
                magnitude.add(math.sqrt(sum(x*x for x in xyz)))
        else:
            if prev_hr_at is not None and (at - prev_hr_at > 5 or at <= prev_hr_at):
                quality['hr_receipt_gaps'] += 1
                previous_rr = None
            prev_hr_at = at
            rr_ticks.extend(decoded['rr_ticks'])
            rr_packets.append({'packet_id': identifier, 'received_at_apple_seconds': at,
                               'contact': decoded['contact'], 'rr_ticks': decoded['rr_ticks']})
            if decoded['contact'] is False:
                quality['off_body_packets'] += 1
                previous_rr = None
                continue
            for value in decoded['rr_ms']:
                if not 300 <= value <= 2000:
                    quality['rr_invalid_count'] += 1
                    previous_rr = None
                    continue
                valid_rr.append(value)
                if previous_rr is not None:
                    diffs.append(value - previous_rr)
                previous_rr = value
    if not seen:
        raise ValueError('empty raw journal')
    means = [a.mean for a in axes] if magnitude.n else None
    scatter = math.sqrt(sum(a.variance for a in axes)) if magnitude.n else None
    norm = math.sqrt(sum(v*v for v in means)) if means else 0
    # Retain direction, not an uncalibrated anatomical posture label. A moving
    # window cannot be represented by a single gravity direction.
    gravity = [v / norm for v in means] if magnitude.n >= 200 and scatter <= 30 and norm > 1 else None
    return {
        'algorithm_version': VERSION, 'packet_counts': counts, 'quality': quality,
        'received_at_apple_seconds': {'first': first_at, 'last': last_at},
        'rr': {'ticks': rr_ticks, 'ticks_per_second': 1024, 'packets': rr_packets,
               'valid_count': len(valid_rr), 'successive_pairs': len(diffs),
               'mean_ms': statistics.mean(valid_rr) if valid_rr else None,
               'sdnn_ms': statistics.stdev(valid_rr) if len(valid_rr) >= 2 else None,
               'rmssd_ms': math.sqrt(statistics.mean(d*d for d in diffs)) if diffs else None,
               'pnn50_pct': 100 * sum(abs(d) > 50 for d in diffs) / len(diffs) if diffs else None,
               'filter': '300-2000ms, contact, receipt gaps; no ectopic classification'},
        'ecg': {'sample_count': ecg.n, 'min_uv': ecg.low, 'max_uv': ecg.high,
                'mean_uv': ecg.mean if ecg.n else None, 'constant_packets': constant_ecg},
        'acc': {'sample_count': magnitude.n, 'mean_xyz_mg': means,
                'magnitude_sd_mg': math.sqrt(magnitude.variance) if magnitude.n else None,
                'vector_scatter_mg': scatter, 'gravity_direction': gravity,
                'position': 'requires sensor orientation calibration'},
    }
