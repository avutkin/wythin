"""Backup integrity must fail closed on loss, corruption and unsafe manifests."""
import gzip
import hashlib
import json
import sys
from datetime import datetime, timezone

import pytest


def api():
    from server import backup
    return backup


def row(payload=b'exact raw bytes\n'):
    return dict(user_id='00000000-0000-0000-0000-000000000001',
        chunk_id='00000000-0000-0000-0000-000000000002',
        sha256=hashlib.sha256(payload).hexdigest(), byte_count=len(payload), storage_backend='s3')


def test_missing_manifest_object_rejects_snapshot():
    with pytest.raises(ValueError, match='missing'):
        api().verify_listing([row()], iter([{'path':'/database.dump'}, {'path':'/manifest.json'}]))


@pytest.mark.parametrize('field,value', [('user_id','../../escape'), ('chunk_id','../escape'),
    ('sha256','../escape'), ('byte_count',-1), ('storage_backend','filesystem')])
def test_invalid_manifest_cannot_escape_or_silently_skip(field, value):
    data = row()
    data[field] = value
    with pytest.raises(ValueError):
        api().object_path(data)


def test_restore_checks_actual_uncompressed_bytes(tmp_path):
    data = row()
    manifest = {'raw_chunks':[data], 'database_sha256': hashlib.sha256(b'dump').hexdigest()}
    (tmp_path/'database.dump').write_bytes(b'dump')
    (tmp_path/'manifest.json').write_text(json.dumps(manifest))
    target = tmp_path / api().object_path(data)
    target.parent.mkdir(parents=True)
    target.write_bytes(gzip.compress(b'exact raw bytes\n'))
    assert api().verify_restore(tmp_path) == 1
    target.write_bytes(gzip.compress(b'different bytes'))
    with pytest.raises(ValueError, match='integrity'):
        api().verify_restore(tmp_path)


def test_restore_rejects_missing_raw_file(tmp_path):
    (tmp_path/'database.dump').write_bytes(b'dump')
    (tmp_path/'manifest.json').write_text(json.dumps({'raw_chunks':[row()],
        'database_sha256':hashlib.sha256(b'dump').hexdigest()}))
    with pytest.raises((ValueError, FileNotFoundError)):
        api().verify_restore(tmp_path)


def test_restore_rejects_damaged_database_dump(tmp_path):
    (tmp_path/'database.dump').write_bytes(b'damaged')
    (tmp_path/'manifest.json').write_text(json.dumps({'raw_chunks':[],
        'database_sha256':hashlib.sha256(b'dump').hexdigest()}))
    with pytest.raises(ValueError, match='database'):
        api().verify_restore(tmp_path)


def test_nonzero_backup_command_is_never_success():
    with pytest.raises(RuntimeError, match='exit 3'):
        api().run([sys.executable, '-c', 'raise SystemExit(3)'])


def test_empty_archive_still_requires_database_and_manifest():
    with pytest.raises(ValueError, match='missing'):
        api().verify_listing([], iter([]))
    api().verify_listing([], iter([{'path':'/database.dump'}, {'path':'/manifest.json'}]))


def test_captured_wrong_bytes_block_completion_even_when_path_exists(tmp_path):
    data = row()
    audit = api().ContentAudit(tmp_path/'audit.sqlite', [data], previous=None)
    audit.listed(iter([{'path':'/database.dump'}, {'path':'/manifest.json'},
        {'path':'/raw-manifest.jsonl'}, {'path':'/'+api().object_path(data)}]))
    with pytest.raises(ValueError, match='integrity'):
        audit.verify(lambda path: gzip.compress(b'wrong bytes'))
    assert audit.previous() is None
    audit.close()


def test_cache_reuses_only_verified_unchanged_content(tmp_path):
    data = row()
    path = '/'+api().object_path(data)
    nodes = [{'path':'/database.dump'}, {'path':'/manifest.json'},
        {'path':'/raw-manifest.jsonl'}, {'path':path}]
    audit = api().ContentAudit(tmp_path/'audit.sqlite', [data], previous=None)
    audit.listed(iter(nodes))
    assert audit.verify(lambda _: gzip.compress(b'exact raw bytes\n')) == 1
    audit.commit('previous-good')
    audit.close()
    audit = api().ContentAudit(tmp_path/'audit.sqlite', [data], previous='previous-good')
    audit.listed(iter(nodes))
    def unexpected_read(_):
        raise AssertionError('unchanged verified data was reread')
    assert audit.verify(unexpected_read) == 0
    audit.changed(iter([{'message_type':'change','path':path,'modifier':'M'}]))
    with pytest.raises(ValueError, match='integrity'):
        audit.verify(lambda _: gzip.compress(b'bad'))
    assert audit.previous() == 'previous-good'
    audit.close()


def test_prune_keeps_both_published_and_new_snapshot_after_long_gap():
    now = datetime(2026,11,15,tzinfo=timezone.utc)
    snapshots = [{'id':name, 'time':'2026-01-01T00:00:00Z'}
                 for name in ('published','new','old')]
    assert api().prune_candidates(snapshots, 'new', 'published', now) == ['old']


@pytest.mark.parametrize('max_files,max_bytes', [(2, 1_000_000), (1000, 32)])
def test_large_archive_validation_restores_bounded_batches(tmp_path, max_files, max_bytes):
    import uuid
    payload = b'exact raw bytes\n'
    rows = [dict(row(), chunk_id=str(uuid.UUID(int=i))) for i in range(1, 6)]
    audit = api().ContentAudit(tmp_path/'audit.sqlite', rows, previous=None)
    batches = []
    def recover(paths, target):
        batches.append(paths)
        for path in paths:
            file = target/path.lstrip('/')
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(gzip.compress(payload))
    assert audit.verify_batches(recover, tmp_path, max_files=max_files, max_bytes=max_bytes) == 5
    assert [len(batch) for batch in batches] == [2, 2, 1]
    assert not list(tmp_path.glob('raw-check-*'))
    audit.close()


def test_batch_restore_rejects_wrong_bytes_without_advancing_verified_state(tmp_path):
    audit = api().ContentAudit(tmp_path/'audit.sqlite', [row()], previous=None)
    def recover(paths, target):
        file = target/paths[0].lstrip('/')
        file.parent.mkdir(parents=True)
        file.write_bytes(gzip.compress(b'wrong'))
    with pytest.raises(ValueError, match='integrity'):
        audit.verify_batches(recover, tmp_path)
    assert audit.previous() is None
    assert not list(tmp_path.glob('raw-check-*'))
    audit.close()
