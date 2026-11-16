import gzip
import hashlib
import io
import uuid

import pytest
from botocore.exceptions import ClientError
from fastapi import HTTPException

from server.archive_store import S3Archive, unpack


class MemoryS3:
    def __init__(self):
        self.objects = {}
        self.calls = []

    def put_object(self, **kw):
        self.calls.append(kw)
        self.objects[kw['Key']] = kw['Body']

    def get_object(self, **kw):
        self.calls.append(kw)
        if kw['Key'] not in self.objects:
            raise ClientError({'Error': {'Code': 'NoSuchKey'}}, 'GetObject')
        return {'Body': io.BytesIO(self.objects[kw['Key']])}

    def list_objects_v2(self, **kw):
        return {'Contents': [{'Key': k} for k in self.objects if k.startswith(kw['Prefix'])]}

    def delete_objects(self, **kw):
        for item in kw['Delete']['Objects']:
            self.objects.pop(item['Key'], None)
        return {}


def test_s3_lossless_encrypted_retry_and_namespace():
    client = MemoryS3()
    store = S3Archive(client, 'private-test', b'x' * 32)
    user, chunk = str(uuid.uuid4()), uuid.uuid4()
    payload = bytes(range(256)) * 4000
    sha = hashlib.sha256(payload).hexdigest()
    store.put(user, chunk, sha, payload)
    store.put(user, chunk, sha, payload)
    assert store.get(user, chunk, sha) == payload
    assert len(client.objects) == 1
    assert all(c['SSECustomerAlgorithm'] == 'AES256' for c in client.calls)
    assert all(c['SSECustomerKey'] == b'x' * 32 for c in client.calls)
    with pytest.raises(HTTPException) as error:
        store.get(str(uuid.uuid4()), chunk, sha)
    assert error.value.status_code == 503


def test_s3_keys_are_content_addressed_and_delete_is_owner_scoped():
    client = MemoryS3()
    store = S3Archive(client, 'private-test', b'x' * 32)
    user, stranger, chunk = str(uuid.uuid4()), str(uuid.uuid4()), uuid.uuid4()
    for owner, data in [(user, b'one'), (user, b'two'), (stranger, b'keep')]:
        store.put(owner, chunk, hashlib.sha256(data).hexdigest(), data)
    assert len(client.objects) == 3
    store.delete_user(user)
    assert store.get(stranger, chunk, hashlib.sha256(b'keep').hexdigest()) == b'keep'
    assert len(client.objects) == 1


def test_corrupt_and_oversized_compressed_archives_are_rejected():
    for compressed in [b'bad gzip', gzip.compress(b'x' * 1_500_001)]:
        with pytest.raises(HTTPException) as error:
            unpack(compressed)
        assert error.value.status_code == 503


def test_s3_delete_failure_is_not_reported_as_success():
    client = MemoryS3()
    store = S3Archive(client, 'private-test', b'x' * 32)
    user, chunk = str(uuid.uuid4()), uuid.uuid4()
    store.put(user, chunk, hashlib.sha256(b'a').hexdigest(), b'a')
    client.delete_objects = lambda **kw: {'Errors': [{'Code': 'AccessDenied'}]}
    with pytest.raises(HTTPException) as error:
        store.delete_user(user)
    assert error.value.status_code == 503


def test_invalid_deflate_stream_becomes_archive_error():
    # Valid gzip header followed by an invalid DEFLATE block.
    with pytest.raises(HTTPException) as error:
        unpack(bytes.fromhex('1f8b0800000000000003') + b'\xff' * 16)
    assert error.value.status_code == 503
