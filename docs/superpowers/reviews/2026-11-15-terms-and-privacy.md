# Terms and privacy review

Independent read-only review covered the root gate, offline legal reader,
receipt persistence, Settings, backwards compatibility and draft notices.

## Findings resolved

1. Cloud Off did not gate legacy session/activity/usage upload and live streaming.
   All six health/profile POST transports now check a shared missing=false
   permission; uploaders retain unsent work. WebSocket begin/send/connect/retry
   checks the same permission and cancels reconnect work on stop.
2. AI enabling while cloud was Off could never synchronize its server permission.
   Settings explains the dependency and prevents enabling without cloud;
   switching any existing permission Off remains possible. AI requests check
   both cloud and AI permission locally before transport.
3. Successful cloud deletion left the profile receipt cache marked as uploaded.
   The confirmed delete response now invalidates that cache. A rejected delete
   preserves it. Future explicit cloud enabling can send the local receipt again.
4. Incorrect device time caused persistent profile validation failures.
   The server retains the client's timestamp claim, its own receipt timestamp
   and a suspect-clock flag, without blocking later profile/permission updates.

The reviewer confirmed the fixes and found no further actionable code defects
in the focused re-review. The first full run with missing=false exposed four
old check-in tests whose upload fixtures had no cloud permission. Fixtures now
explicitly enable cloud for their upload/retry scenarios.

## Verification

- Full iOS: **1,704 tests passed**, zero failures; `/tmp/wythin-terms-ios-final.log`.
- Full server: **198 tests passed**; `/tmp/wythin-terms-server-reviewed.log`.
- Negative tests reproduced transport bypass, deletion-cache and skewed-clock
  defects before their fixes.
- Local HTML links/anchors and absent automatic external resource loads checked;
  Xcode bundles the same three files used by GitHub Pages, with no second copy.
- `git diff --check` passed.

## Release boundary

This approves continued draft-PR review, not legal compliance or production.
The public documents are marked draft/not effective. The operator confirmed an
individual business, the supplied San Francisco address and an 18+ audience.
User authentication, server enforcement of coaching purpose/revocation, vendor
agreements, full account/recipient/backup deletion, retention and incident
response remain release requirements. No physical overnight test has run.
The primary storage bucket was purchased separately; no archive upload or daily
worker has been enabled in production.
