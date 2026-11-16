"""Lossless archive storage; never fall back to the API system disk."""
from __future__ import annotations

import base64
import gzip
import hashlib
import io
import os
import shutil
import uuid
import zlib
from pathlib import Path
from fastapi import HTTPException

MAX_BYTES = 1_500_000


def unpack(compressed: bytes) -> bytes:
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as stream:
            data = stream.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise ValueError('expanded archive exceeds limit')
        return data
    except (OSError, EOFError, ValueError, zlib.error) as exc:
        raise HTTPException(503, 'archived chunk is corrupt') from exc


def checked(data: bytes, digest: str) -> bytes:
    if hashlib.sha256(data).hexdigest() != digest:
        raise HTTPException(503, 'archived chunk is corrupt')
    return data


def archive_root() -> Path:
    configured = os.getenv('RAW_ARCHIVE_ROOT')
    if not configured:
        raise HTTPException(503, 'raw archive is not configured')
    root = Path(configured)
    if not root.is_dir():
        raise HTTPException(503, 'raw archive is unavailable')
    if os.getenv('RAW_ARCHIVE_REQUIRE_MOUNT', '1') != '0' and not os.path.ismount(root):
        raise HTTPException(503, 'raw archive volume is not mounted')
    return root


class FileArchive:
    backend = 'filesystem'

    def __init__(self, root):
        self.root = root

    def path(self, user, chunk):
        return self.root / str(uuid.UUID(str(user))) / f'{uuid.UUID(str(chunk))}.jsonl.gz'

    def get(self, user, chunk, digest):
        try:
            with self.path(user, chunk).open('rb') as stream:
                compressed = stream.read(MAX_BYTES + 100_001)
            if len(compressed) > MAX_BYTES + 100_000:
                raise ValueError('oversized archive')
            return checked(unpack(compressed), digest)
        except (OSError, ValueError) as exc:
            raise HTTPException(503, 'archived chunk is unavailable') from exc

    def put(self, user, chunk, digest, payload):
        path = self.path(user, chunk)
        if path.exists():
            self.get(user, chunk, digest)
            return
        if shutil.disk_usage(self.root).free < len(payload) + 1_000_000_000:
            raise HTTPException(507, 'raw archive volume is nearly full')
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(f'.{chunk}.{uuid.uuid4()}.tmp')
        try:
            with temporary.open('xb') as output:
                output.write(gzip.compress(payload, compresslevel=6, mtime=0))
                output.flush()
                os.fsync(output.fileno())
            try:
                os.link(temporary, path)
            except FileExistsError:
                self.get(user, chunk, digest)
            fd = os.open(path.parent, os.O_DIRECTORY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        except OSError as exc:
            raise HTTPException(503, 'raw archive write failed') from exc
        finally:
            temporary.unlink(missing_ok=True)

    def delete_user(self, user):
        try:
            shutil.rmtree(self.root / str(uuid.UUID(str(user))))
        except FileNotFoundError:
            pass
        except OSError as exc:
            raise HTTPException(503, 'raw archive deletion failed') from exc


class S3Archive:
    backend = 's3'

    def __init__(self, client, bucket, encryption_key):
        if len(encryption_key) != 32:
            raise HTTPException(503, 'raw archive encryption is not configured')
        self.client, self.bucket = client, bucket
        self.encryption = {'SSECustomerAlgorithm': 'AES256', 'SSECustomerKey': encryption_key}

    def prefix(self, user):
        return f'raw/v1/{uuid.UUID(str(user))}/'

    def key(self, user, chunk, digest):
        if len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
            raise ValueError('invalid digest')
        # Content addressing prevents overwrite after a timed-out PUT whose
        # manifest transaction never committed. DB user locks serialize uploads.
        return f'{self.prefix(user)}{uuid.UUID(str(chunk))}/{digest}.jsonl.gz'

    def put(self, user, chunk, digest, payload):
        from botocore.exceptions import BotoCoreError, ClientError
        try:
            self.client.put_object(Bucket=self.bucket, Key=self.key(user, chunk, digest),
                                   Body=gzip.compress(payload, compresslevel=6, mtime=0),
                                   ContentType='application/gzip',
                                   Metadata={'sha256': digest}, **self.encryption)
        except (BotoCoreError, ClientError) as exc:
            raise HTTPException(503, 'raw object storage write failed') from exc

    def get(self, user, chunk, digest):
        from botocore.exceptions import BotoCoreError, ClientError
        try:
            response = self.client.get_object(Bucket=self.bucket,
                                             Key=self.key(user, chunk, digest), **self.encryption)
            body = response['Body']
            try:
                data = body.read(MAX_BYTES + 100_001)
            finally:
                body.close()
            if len(data) > MAX_BYTES + 100_000:
                raise ValueError('oversized archive')
            return checked(unpack(data), digest)
        except (BotoCoreError, ClientError, OSError, ValueError) as exc:
            raise HTTPException(503, 'archived chunk is unavailable') from exc

    def delete_user(self, user):
        from botocore.exceptions import BotoCoreError, ClientError
        try:
            while True:
                page = self.client.list_objects_v2(Bucket=self.bucket, Prefix=self.prefix(user), MaxKeys=1000)
                objects = [{'Key': x['Key']} for x in page.get('Contents', [])]
                if not objects:
                    return
                result = self.client.delete_objects(Bucket=self.bucket, Delete={'Objects': objects})
                if result.get('Errors'):
                    raise HTTPException(503, 'raw object storage deletion failed')
        except (BotoCoreError, ClientError) as exc:
            raise HTTPException(503, 'raw object storage deletion failed') from exc


def get_archive(backend=None):
    backend = backend or os.getenv('RAW_ARCHIVE_BACKEND', 'filesystem')
    if backend == 'filesystem':
        return FileArchive(archive_root())
    if backend != 's3':
        raise HTTPException(503, 'unknown raw archive backend')
    import boto3
    from botocore.config import Config
    from urllib.parse import urlparse
    endpoint, bucket = os.getenv('RAW_S3_ENDPOINT', ''), os.getenv('RAW_S3_BUCKET', '')
    if urlparse(endpoint).scheme != 'https' or not bucket:
        raise HTTPException(503, 'raw object storage is not configured')
    try:
        key = base64.b64decode(os.getenv('RAW_S3_ENCRYPTION_KEY', ''), validate=True)
    except ValueError as exc:
        raise HTTPException(503, 'raw archive encryption is not configured') from exc
    if len(key) != 32 or not os.getenv('RAW_S3_ACCESS_KEY') or not os.getenv('RAW_S3_SECRET_KEY'):
        raise HTTPException(503, 'raw object storage credentials are not configured')
    client = boto3.client('s3', endpoint_url=endpoint,
                          region_name=os.getenv('RAW_S3_REGION', 'hel1'),
                          aws_access_key_id=os.environ['RAW_S3_ACCESS_KEY'],
                          aws_secret_access_key=os.environ['RAW_S3_SECRET_KEY'],
                          config=Config(connect_timeout=5, read_timeout=30,
                                        retries={'max_attempts': 2, 'mode': 'standard'},
                                        s3={'addressing_style': 'path'}))
    return S3Archive(client, bucket, key)
