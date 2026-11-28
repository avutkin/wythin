# Recording delivery under scheduling delays

The user authorized reproducing and fixing the build 161 diagnostic failures, including the Sydney timezone ambiguity. This extends the recording resilience work already released internally in build 163. It does not authorize external TestFlight distribution.

## Evidence and approach

Capture audit counts advance on the BLE queue before MainActor delivery. Standby and recovery currently consult only MainActor timestamps, so queued healthy packets can look like missing signals. Standby dwell also counts unobserved time between evaluations. A separate, bounded receipt clock keyed to the active characteristic will supply positive liveness evidence before MainActor processing. It must be reset on stop/disconnect and reject old sources/epochs. RR and each PMD stream remain independent; actual outages still recover.

Computed results currently repeat the five-second admission freshness check after computation. A valid admitted window may be saved with its original capture timestamp after scheduling delay, but must not become a live reading or trigger live notifications. Connection/generation changes still discard it. Persist before optional downstream work. Add reasoned, bounded local diagnostics for delayed/discarded computation and BLE delivery latency.

UTC timestamps remain canonical. Export explicit device timezone, offset and local export time; label device uptime accurately and separately record recording-environment uptime. Sydney is a test case, not a hardcoded user timezone. Test DST and midnight boundaries, as well as monotonic timing across wall-clock changes.

## Alternatives and constraints

Increasing every timeout would delay real recovery and not fix false liveness decisions. A complete capture/database actor rewrite is larger than the demonstrated defects. Use the existing callback, generation and persistence architecture with narrow policies and tests. No fabricated samples, interpolation, global timezone changes, schema migration, new dependencies, production data changes or claims that OS termination is fixed. Keep Garmin support. Radio/encryption timeouts and the reason iOS relaunched the process cannot be eliminated or diagnosed from this export alone. Small upload batches are not evidence of loss and are out of scope absent a reproduction.

## Validation

Deterministic delayed-delivery, source replacement, disconnect, independent-stream outage, delayed metric persistence, generation rejection and Australia/Sydney export tests; then the full WythinTests suite and an independent whole-change review. Physical iPhone/H10 overnight behavior requires a subsequent device run.
