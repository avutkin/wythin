# Continuous Polar capture — design

## Intent

Record the Polar H10's ECG (130 Hz), accelerometer (200 Hz), and heart-rate/RR notifications at their delivered resolution during 24/7 wear. Retain them locally before attempting network transfer, send them to the server without duplication, and derive scalar metrics from arriving sensor data in foreground and background. Make genuine Bluetooth or app-execution gaps visible rather than presenting old values as live.

## Constraints and limits

- iOS can suspend or terminate background execution, and Polar cannot supply samples it did not transmit. No app can guarantee 100% coverage; capture every notification delivered to Wythin and report missing intervals.
- Raw ECG and ACC are explicitly authorized for server storage. Budget for roughly 100–200 MB per participant per day before compression.
- Use the Polar packet's device timestamp and retain a phone receipt timestamp. Do not synthesize samples across a gap.
- Existing scalar history, sleep data, and user IDs must remain readable. Existing stores and production data must not be replaced.
- Local persistence precedes upload acknowledgement. Upload retries are idempotent and resume after restarts or offline periods.

## Design

1. A durable append-only raw packet journal receives the original PMD and HR notification bytes synchronously on Core Bluetooth's serial callback queue, before callback return. Each packet has a stable client-generated identity, stream type, receipt time, and device nanosecond time where available. File segments are rotated into immutable chunks. A failed upload leaves the segment pending.
2. The server stores losslessly compressed JSONL segments on a separately mounted archive volume, with a per-user unique chunk identity and SHA-256 integrity manifest in PostgreSQL. It acknowledges exact accepted bytes so the client removes a segment only after success. User-scoped bearer endpoints permit export; the existing personal-data deletion endpoint also removes raw chunks.
3. Metric computation is triggered by fresh RR/ECG events, coalesced to an approximately two-second cadence in both app states. An independent timer may refresh foreground presentation but cannot be the sole source of stored points. No fresh sensor data means no new physiological point.
4. The client exposes last ECG, motion, and RR timestamps, local recording and upload errors, and the pending chunk count. The 24-hour chart retains a full-day axis so missing time is visible. A server-side packet coverage summary remains future work.
5. Validation includes parser and journal recovery tests, server idempotency and user-scope tests, a background-delivery simulation that requires points without a timer wake, an offline retry simulation, and a real-device overnight test with the app backgrounded.

## Decisions

- Full raw cloud storage is the user's choice. The raw upload is asynchronous and resumable; network connectivity cannot be a prerequisite for recording.
- Keep derived metrics at the existing approximately two-second maximum. Raw sensor packets retain the native device resolution rather than being resampled to this metric cadence.
- No automatic deletion of unsent packets. Successful uploads are removed from the local queue after digest acknowledgement. The server archive has no automatic retention expiry and must use separately provisioned durable storage, backups, and capacity monitoring.
- Raw cloud upload is a separate opt-in toggle. Local raw recording continues when cloud sync is off.
