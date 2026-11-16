# Full signal archive review and release status

Reviewed base 62c0cd3 through 8bfbd25 by an independent read-only reviewer. Four
Important findings, no Critical findings. The implementer fixed them in one
regression-test pass; no claim of live activation is made.

| Finding | Evidence and resolution |
|---|---|
| Delayed enable outlives a refusal | Restored the old false-read shortcut in the new runtime test: the PUT was absent and the test failed. Every unsynchronized refusal now writes a revision barrier; CAS conflicts reconcile. Server test queues enable and refusal behind the same lock, simulates client timeout, and verifies final disabled revision 2. |
| Erasure silently re-enables capture | Test failed when deletion reset revision to 0. Erasure now leaves a disabled monotonic barrier; client stops capture/sync before deletion and does not rebase a previous acceptance over a server pause. New explicit acceptance can resume. HTTP deletion failure is also surfaced. |
| Malformed packet stops daily worker | Integer/list/object IDs reproduced AttributeError. Parser validates record/UUID types and normalizes bad metadata to ValueError. Tests verify failed chunk followed by successfully processed valid chunk. |
| Missing RR falsely treated as continuous | RR, ten HR-only notifications, RR reproduced an invalid successive pair. Empty RR packets now break continuity; exact ticks and empty packet records remain preserved. |

Verification after fixes: **191 server tests passed; 1694 WythinTests passed**
on iPhone 17e simulator. `git diff --check` clean. Real S3, backup restore,
physical strap overnight recording and activation are not verified.

## Decisions and unresolved boundaries

- S3 primary rather than a 1 TB Volume: fits the discussed storage budget;
  requires the adapter, account credentials and live provider verification.
- No age-only deletion: retained RR and backups must be validated first;
  storage continues growing in the meantime.
- First daily algorithm is a per-chunk signal audit, not full daily HRV or a
  cognitive/mood assessment. Cross-chunk methods, device-clock continuity and
  calibrated posture remain future versioned work; exact sources are retained.
- Live provider completion after a timed-out PUT has not been certified. The
  release fault test must cover orphan cleanup and deletion ordering; database
  locks do not prove that a provider-side late write cannot appear afterwards.
- Filesystem symlink attacks require separate local server compromise. UUID and
  digest normalization prevent API path traversal; OS hardening remains a
  deployment responsibility.
- Team/AI mandatory-versus-optional onboarding remains an unanswered product
  choice. Their existing defaults and administrative enforcement are unchanged.
  Do not claim this work has made team-sharing withdrawal a new access boundary.
- Existing shared-key/device-ID issuance is not strong end-user authentication.
  Owner-token export isolation tests do not validate who can obtain that token.
  Review and resolve this before activating a broad sensitive-signal archive.
- Backup/retention/provisioning/physical validation remain explicit release
  blockers. No resources were purchased, production was not changed, and the
  client availability flag remains false.

Minor findings deferred by reviewer: none. No merge or activation approval is
implied by green local tests. The branch is a prepared implementation awaiting
external dependencies and final product decisions.
