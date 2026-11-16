# Full signal archive and daily analysis

User request: preserve every available Polar H10 stream, support up to 100
participants, process new data once daily, provision Hetzner storage, and update
onboarding and the data protocol. Position means body orientation from ACC, not GPS.

## Data contract

- Preserve exact ECG, ACC XYZ and Heart Rate notifications (including original
  1/1024-second RR values), device timestamps and receipt timestamps.
- Compression must be lossless. Preserve checksum, schema/algorithm versions,
  gaps, unsupported frames and contact/quality information. Never pretend receipt
  time is an exact beat timestamp or that an uncalibrated axis is a body posture.
- Private S3-compatible storage is preferred over a 1 TB block Volume: the
  latter materially exceeds the storage budget discussed. Existing filesystem
  archives continue to work. Owner exports and deletion must cover both backends.
- Daily processing is incremental, bounded, retryable and idempotent; derived
  output retains provenance. No raw ECG is sent to a language-model provider.
- Processing describes signal quality, RR statistics and motion/orientation.
  Mood, attention and cognitive abilities are not inferred as established facts.

## Consent and rollout

No historical refusal becomes consent. Capture and upload require an explicit,
versioned archive acceptance. Declining the core archive onboarding may stop the
cloud programme; it cannot prevent an App Store download. Settings can stop new
collection and transmission. Existing pending uploads must respect revocation.
Team access and external AI are separately described purposes; the product choice
about making them optional is awaiting the user's answer. Do not deploy a
contradictory or undisclosed consent flow in the meantime.

## Capacity and retention

Planning estimate only: 5–10 GB/participant/30 days, 0.5–1 TB for 100; benchmark
actual gzip size before widening rollout. Primary Object Storage EUR 6.49/month
base including 1 TB; BX11 independent backup EUR 3.20/month, excluding VAT,
compute, AI and overages (official public prices checked 2026-11-15).
1 TB at the upper estimate has no headroom. Alert at 70%, act before 85%.

Keep full streams for 30 days before eligibility for compaction. RR, quality,
minute/day summaries, context and selected ECG/ACC segments survive compaction.
Automatic deletion remains disabled until compact outputs and an independent
backup have been restored and verified. Mere object age is not sufficient.

## Release gates

Storage purchase requires the authenticated Hetzner project and actual quote;
do not create a substitute on the API system disk. Provision private storage,
backup and credentials, test exact upload/download and owner isolation, verify
restore, run server and full iOS tests, then an overnight physical strap test.
Only then activate broad collection. Repository shipping uses tools/ship.sh.
