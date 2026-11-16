# Full signal archive implementation

Goal: exact ECG/RR/ACC preservation with a private scalable backend and daily
incremental processing for up to 100 users.

Architecture: existing bounded JSONL upload, interchangeable durable stores,
PostgreSQL manifest and consent history, independent daily worker.

Tech stack: Swift/iOS, FastAPI/asyncpg, Python, S3-compatible storage, systemd.

Spec: ../specs/2026-11-15-full-signal-archive.md

Global constraints: preserve unrelated work; keep existing opt-outs; lossless
data; no production secrets in logs; no unverified raw deletion; no release
before infrastructure and tests. Authenticated console and legal/security gates are
external dependencies, not reasons to stop independent implementation.

## Task 1: Durable object storage

Interfaces: store.put/get/delete_user; upload checksum/ack unchanged; owner
download and deletion work for filesystem and S3.
Write failing tests for retries, corruption, unavailable storage and deletion;
implement bounded S3 adapter, retain mount protections, run all server tests.
Expected: no ack without durable exact bytes, no overwrite on conflict.

## Task 2: Daily raw processing

Interfaces: manifest rows -> exact decoded RR/ECG/ACC with provenance -> versioned
per-chunk results. Write fixture tests for signed ECG/ACC, RR flags and precision,
malformed/unsupported packets, retry handling and statistics across gaps.
Implement bounded worker and daily systemd timer. Run tests.
Expected: replay does not duplicate output; corrupt input is not marked complete.

## Task 3: Consent and client rollout

Interfaces: explicit acceptance/version -> local capture + cloud upload gates,
server consent state/history -> reject revoked upload/processing. Follow the
terms-and-privacy amendment for mandatory contract versus data permissions. Test absence, refusal,
upgrade, revocation and backlog behaviour. Run full WythinTests and server tests.
Expected: no automatic conversion of existing refusals; clear onboarding copy.

## Task 4: Provision, verify, protocol

Use authenticated project inventory and reviewed tariff to purchase primary and
independent backup within the agreed budget, configure private access, verify
round-trip and restore, update runbook. Record blockers honestly. Do not fake
phone overnight verification. Final fresh-context code review and fix critical
findings, then integrate and ship only when gates are met.

Review focus: storage timeouts after successful writes, deletion/upload races,
stale consent retries, corrupt gzip, untrusted paths, day-boundary gaps, clock
resets, double processing and physical sensor calibration limits.
