"""Verify a private SSE-C archive using a disposable synthetic-only prefix.

Run in an isolated environment, not the API process:
    python -m server.tools.verify_archive_storage /etc/wythin/archive-staged.env
No real user identifier, recording, manifest or consent record is read.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import sys
import uuid

import boto3
from botocore import UNSIGNED
from botocore.config import Config
from botocore.exceptions import ClientError

from server.archive_store import get_archive


def main(path: str) -> None:
    for line in Path(path).read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        if not key.startswith("RAW_"):
            raise ValueError("unexpected configuration key")
        os.environ[key] = value

    archive = get_archive("s3")
    client = archive.client
    acl = client.get_bucket_acl(Bucket=archive.bucket)
    assert all(grant["Grantee"].get("Type") == "CanonicalUser"
               and grant["Grantee"].get("ID") == acl["Owner"]["ID"]
               for grant in acl["Grants"]), "bucket grants access beyond its owner"
    versioning = client.get_bucket_versioning(Bucket=archive.bucket)
    assert versioning.get("Status") != "Enabled", "version-history deletion is not implemented"

    anonymous = boto3.client("s3", endpoint_url=os.environ["RAW_S3_ENDPOINT"],
        region_name=os.environ["RAW_S3_REGION"],
        config=Config(signature_version=UNSIGNED, connect_timeout=5, read_timeout=20,
                      retries={"max_attempts": 1}, s3={"addressing_style": "path"}))
    try:
        anonymous.list_objects_v2(Bucket=archive.bucket, MaxKeys=1)
    except ClientError as error:
        assert error.response["ResponseMetadata"]["HTTPStatusCode"] == 403
    else:
        raise AssertionError("anonymous bucket listing must be denied")

    # Random UUIDs are created here, never derived from users or their records.
    user, chunk = str(uuid.uuid4()), str(uuid.uuid4())
    payload = (json.dumps({"purpose": "synthetic storage verification",
        "contains_user_data": False, "rr_ticks": [1024, 1000, 990],
        "ecg_uv": [0, 120, -80, 0], "acc_xyz": [[0, 0, 1000], [1, 0, 1000]]},
        sort_keys=True) + "\n").encode()
    digest = hashlib.sha256(payload).hexdigest()
    try:
        archive.put(user, chunk, digest, payload)
        assert archive.get(user, chunk, digest) == payload, "round-trip changed bytes"
        head = client.head_object(Bucket=archive.bucket,
            Key=archive.key(user, chunk, digest), **archive.encryption)
        assert head.get("SSECustomerAlgorithm") == "AES256", "SSE-C not confirmed"
        assert head.get("Metadata", {}).get("sha256") == digest
        try:
            response = client.get_object(Bucket=archive.bucket, Key=archive.key(user, chunk, digest))
        except ClientError as error:
            assert error.response["ResponseMetadata"]["HTTPStatusCode"] in (400, 403)
        else:
            response["Body"].close()
            raise AssertionError("object must not be readable without its encryption key")
    finally:
        archive.delete_user(user)
    remaining = client.list_objects_v2(Bucket=archive.bucket, Prefix=archive.prefix(user))
    assert not remaining.get("Contents"), "synthetic verification objects remain"
    print(json.dumps({"private_acl": True, "anonymous_list_denied": True,
        "versioning_enabled": False, "sse_c": "AES256", "exact_round_trip": True,
        "synthetic_sha256": digest, "synthetic_bytes": len(payload),
        "synthetic_objects_deleted": True, "production_capture_enabled": False}, sort_keys=True))


if __name__ == "__main__":
    main(sys.argv[1])
