import base64
import json
import math
import struct
import uuid

import pytest
from server.raw_analysis import analyze_chunk, decode_notification


def packet(stream, payload, received=816480000, identifier=None):
    return json.dumps({'id': identifier or str(uuid.uuid4()), 'stream': stream,
                       'receivedAt': received, 'payload': base64.b64encode(payload).decode()}) + '\n'


def test_exact_signed_ecg_acc_and_rr_precision():
    ecg = b'\x00' + struct.pack('<Q', 123456789) + b'\x00' + b'\xff\xff\xff\x00\x00\x80\xff\xff\x7f'
    assert decode_notification('ecg', ecg)['samples'] == [-1, -8388608, 8388607]
    acc = b'\x02' + struct.pack('<Q', 123456789) + b'\x01' + struct.pack('<hhh', -32768, 0, 32767)
    assert decode_notification('acc', acc)['samples'] == [(-32768, 0, 32767)]
    hr = b'\x1f' + struct.pack('<HHHH', 300, 50, 1025, 1000)
    result = decode_notification('hr', hr)
    assert result['rr_ticks'] == [1025, 1000]
    assert result['rr_ms'] == [1000.9765625, 976.5625]
    assert result['contact'] is True and result['bpm'] == 300


def test_unknown_frame_types_never_get_interpreted_as_samples():
    with pytest.raises(ValueError):
        decode_notification('acc', b'\x02' + b'\x00' * 8 + b'\x80' + b'\x00' * 6)
    with pytest.raises(ValueError):
        decode_notification('hr', b'\x10\x3c\x00')


def test_rr_gaps_contact_and_invalid_values_do_not_create_successive_pairs():
    data = packet('hr', b'\x16\x3c' + struct.pack('<HH', 1024, 1126), 1000)
    data += packet('hr', b'\x14\x3c' + struct.pack('<H', 900), 1001)  # off body
    data += packet('hr', b'\x16\x3c' + struct.pack('<H', 1024), 1020) # gap
    data += packet('hr', b'\x16\x3c' + struct.pack('<HHH', 0, 1024, 1126), 1021)
    result = analyze_chunk(data.encode())
    assert result['rr']['ticks'] == [1024, 1126, 900, 1024, 0, 1024, 1126]
    assert result['rr']['successive_pairs'] == 2
    assert result['rr']['rmssd_ms'] == pytest.approx(102 * 1000 / 1024)
    assert result['quality']['off_body_packets'] == 1
    assert result['quality']['rr_invalid_count'] == 1
    assert result['quality']['hr_receipt_gaps'] == 1


def test_duplicate_packet_and_corrupt_json_are_not_silently_counted_twice():
    one = packet('hr', b'\x10\x3c\x00\x04', identifier=str(uuid.uuid4()))
    result = analyze_chunk((one + one).encode())
    assert result['rr']['ticks'] == [1024]
    assert result['quality']['duplicate_packets'] == 1
    with pytest.raises(ValueError):
        analyze_chunk((one + '{truncated').encode())


def test_flatline_and_motion_are_described_without_claiming_mood_or_position():
    ecg = b'\x00' + struct.pack('<Q', 123) + b'\x00' + b'\x00' * 390
    acc = b'\x02' + struct.pack('<Q', 123) + b'\x01' + struct.pack('<hhh', 0, 0, -1000) * 200
    result = analyze_chunk((packet('ecg', ecg) + packet('acc', acc)).encode())
    assert result['ecg']['sample_count'] == 130
    assert result['ecg']['constant_packets'] == 1
    assert result['acc']['mean_xyz_mg'] == [0, 0, -1000]
    assert result['acc']['magnitude_sd_mg'] == 0
    assert result['acc']['gravity_direction'] == [0, 0, -1]
    assert 'mood' not in result and 'diagnosis' not in result
