# Breath rate resilience — design

**Date:** 2026-08-09
**Status:** approved, ready to implement

## Problem

On 2026-08-07 the Breath Rate chart was empty for the first twenty minutes of a
session while every other metric on screen — Stress Balance, Conscious Breathing,
Calm Power — ran continuously. The asymmetry is the diagnosis: those three derive
from RR intervals, and Breath Rate is the only accelerometer-derived metric on the
Live screen. There were no anomaly bands, so `MetricsQualityFilter` passed every
tick; the tick filter drops whole samples and would have punched the same hole
through all four charts.

`breathBPM` is `BreathingCompute.computeRate(accZ:)?.bpm`, which returns nil when the
ACC ring buffer holds less than the minimum sample count. That buffer is fed only by
`DataBuffer.appendACC`, which runs only when PMD accelerometer notifications arrive.
No ACC stream, no buffer, no breath rate.

`BLEService.swift:49-55` already documents the cause: `launchStreams` serialises the
ECG and ACC start commands on a fixed 250 ms timer without waiting for the H10's
response, so a lost ACC start "silently disables breathing detection until the next
reconnect or standby cycle". A watchdog exists for exactly this. It did not save us,
and there are two reasons why:

1. **`giveUp` is terminal.** Three retries at a 5 s gap is roughly twenty seconds,
   then `accWatchdogTask?.cancel()` at `BLEService.swift:638`. Only `launchStreams →
   startACCWatchdog` re-arms it. After twenty seconds the app stops trying for the
   rest of the session.
2. **ECG silence vetoes the watchdog.** `ACCWatchdogPolicy.decide` guards on
   `ecgFlowing`, deferring to the reconnect machinery when both PMD streams are
   quiet. But ECG and ACC are both PMD streams, while RR arrives on a separate
   `heartRateService` characteristic. When PMD delivery stalls as a whole and RR
   keeps flowing, the link looks healthy, the reconnect watchdog has nothing to act
   on, and the ACC watchdog stays deliberately silent. Nobody retries.

A third weakness compounds both: neither `accZBuf` nor `ecgBuf` carries timestamps or
ages out. A *mid-session* ACC death therefore produces no gap at all — `computeRate`
keeps grinding the last 60 s of stale samples and returns a constant, so the chart
shows a flat line indistinguishable from real data. The clean gap we observed tells
us the buffer was empty, i.e. ACC never started, rather than dying partway.

## What we're building

Three things, separable but shipped together:

1. **Fix the watchdog** so a PMD stall is detected via RR liveness and retried
   indefinitely rather than abandoned after twenty seconds.
2. **Add an ECG-derived respiration (EDR) fallback** so Breath Rate survives a total
   PMD stall, since RR arrives on a different characteristic.
3. **Improve the accelerometer estimator itself** — use all three axes, and raise the
   frequency resolution.

### Non-goal: EDR does not replace the accelerometer

The two sources fail in almost disjoint conditions. ACC fails when you are moving;
RSA-derived EDR fails when heart rate is high or vagal tone is low, because the
respiratory modulation it reads collapses. Neither dominates, so EDR is a fallback
only — it fills in when ACC returns nil and is never preferred over a live ACC
reading.

### Non-goal: syncing the source field

`breathSource` is persisted locally but deliberately kept out of the `Sync/APIClient`
payload and the server model. It can be added later without a migration.

## 1 · SpectralPeak

`BreathingCompute.computeRate` contains peak-picking logic that both estimators need:
find the strongest strict local maximum inside a band, require it to carry a minimum
multiple of the mean in-band power, then refine it to sub-bin precision. Extract it.

```swift
enum SpectralPeak {
    struct Result {
        let hz:         Float
        let peakToMean: Float
    }

    static func dominant(freqs: [Float],
                         psd: [Float],
                         searchBand: ClosedRange<Float>,
                         acceptBand: ClosedRange<Float>,
                         minPeakToMean: Float) -> Result?
}
```

**`searchBand` and `acceptBand` are separate parameters and must stay separate.** The
PSD is searched over a wider window than rates are accepted from so that every
candidate inside the accept band has a neighbouring bin on each side to be a strict
local maximum against. Without the margin, a candidate sitting on the band edge has
nothing to compare against and the argmax of a monotonically decaying spectrum
silently becomes the reported rate. Per the comments at `BreathingCompute.swift:48-55`
this has already produced two artefact floors in production — an 8.79 br/min floor,
then a 5.86 floor once the edge moved. Collapsing these into one band during
extraction reintroduces both.

`refinePeakHz` moves here unchanged. Its existing tests move with it.

## 2 · EDRCompute

```swift
enum EDRCompute {
    static let searchBand:    ClosedRange<Float> = 0.10...0.60
    static let acceptBand:    ClosedRange<Float> = 0.15...0.50   // 9–30 br/min
    static let minPeakToMean: Float = 3.0
    static let minBeats:      Int   = 60

    /// Breathing rate in br/min from the RR tachogram, or nil.
    static func computeRate(rrMs: [Int]) -> Float?
}
```

Pipeline: `HRVCompute.cleanRR` → guard `count >= minBeats` → `interpTachogram(fs:
HRVCompute.rrFS)` → detrend → `welchPSD(nperseg: min(256, count))` → `SpectralPeak`
→ `hz * 60`.

At `rrFS = 4.0 Hz` with `nperseg = 256`, the bin width is 0.0156 Hz — **0.94 br/min**,
roughly three times finer than the accelerometer path — over a 64 s window. The
machinery already exists; this reuses it.

### The accept band starts at 0.15 Hz, not 0.08

Below roughly 0.15 Hz the respiratory peak cannot be separated from the Mayer wave, a
genuine blood-pressure oscillation near 0.1 Hz that sits exactly on 6 br/min. A
spectral method cannot tell them apart. Reporting the peak anyway would mean telling
someone breathing spontaneously at 14 br/min that they are at 6.

Returning nil below 9 br/min costs nothing in practice. The fallback only fires when
ACC is unavailable, which is overwhelmingly when the user is moving — and nobody
breathes at 6 br/min while moving. When they genuinely are doing paced resonance
work they are still, so ACC is working and EDR is not consulted. This removes the
ambiguity rather than mitigating it.

## 3 · BreathingCompute changes

### Three axes

`computeRate` takes `accXYZ: [SIMD3<Float>]` instead of `accZ: [Float]`. Z is
nominally chest-normal and is the right axis, but a strap that has rotated on the
torso moves chest expansion into X and Y, shrinking the Z projection until the
peak-to-mean guard rejects it.

Evaluate Z first. If it yields a result, use it — this is the common case and costs
exactly what it costs today. Only when Z fails do X and Y get evaluated, and the
candidate with the highest `peakToMean` wins. Worst case is three Welch transforms
per tick, and only in the case that currently produces nothing at all.

An `accZ` overload is retained for tests and for callers that already hold a Z array.

### Frequency resolution, and the buffer growth it forces

`nperseg` rises from 4096 to 8192. `welchPSD` floors the segment length to a power of
two, so at 200 Hz this takes the bin width from 0.0488 Hz (**2.93 br/min**) to
0.0244 Hz (**1.46 br/min**).

Raising `nperseg` alone is not enough, because `welchPSD` averages only whole
segments: `while start + fftLen <= n` with `step = fftLen / 2`. Against the current
12000-sample buffer that gives

| fftLen | segments averaged |
|--------|-------------------|
| 4096 (today) | 4 |
| 8192 (12000-sample buffer) | **1** |
| 8192 (16384-sample buffer) | 3 |

At 8192 over a 60 s buffer only one segment fits, so the Welch estimate degrades to a
bare periodogram — four times less averaging than today, and periodogram variance is
what makes a spectral peak jitter between bins in the first place. That trades one
error for a worse one.

So the ACC buffers grow with the window: `accZBuf` and `accXYZBuf` go from 12000 to
**16384 samples (81.9 s)**, which restores 3 averaged segments at the finer
resolution. Memory cost is about 320 KB across both buffers.

The trade is responsiveness: the span informing one estimate grows from 60 s to 82 s.
Breathing rate is not a fast-moving quantity and the card already applies
three-bucket smoothing, so this is acceptable — but it is a real change, not a free
one.

**`CoherenceCompute` must be insulated from the buffer growth.** It takes `accZ`
directly and strides over `accZ.count`, so a longer buffer would silently widen its
analysis window too. It changes to take the last 12000 samples explicitly, keeping
its behaviour identical.

This changes the character of every reading. Data recorded before this change was
sampled at the old resolution, so historical comparisons shift slightly.

### Minimum buffer

`minAccBreath` rises from 6 s to **4096 samples (20.5 s)**.

Because `welchPSD` floors to a power of two, short buffers collapse silently. At the
current 6 s minimum the FFT length is 1024, giving a bin width of 0.195 Hz — **11.7
br/min**, which spans the entire accept band in about two bins. Those early readings
are noise wearing a number.

At 4096 the resolution can never fall below today's 2.93 br/min, improving to
1.46 br/min once 41 s has buffered. The visible cost is that the first breath reading
appears roughly 20 s after strap-on instead of 6 s.

## 4 · Selection, and the anti-circularity rule

In `MetricsEngine.compute`:

```swift
let acc = BreathingCompute.computeRate(accXYZ: snapshot.accXYZ)
let edr = acc == nil ? EDRCompute.computeRate(rrMs: rrMs) : nil

breathBPM    = acc?.bpm ?? edr
breathSource = acc != nil ? .accelerometer : (edr != nil ? .heart : nil)
breathHz     = acc?.peakHz         // never edr
regularity   = acc?.regularity     // never edr
```

```swift
enum BreathSource: Int, Codable {
    case accelerometer = 0
    case heart         = 1
}
```

**`breathHz` and `regularity` stay accelerometer-only.** `RSACompute` uses `breathHz`
to place a bandpass; `CoherenceCompute` correlates the RR tachogram against the ACC
signal; CBI combines both plus `regularity`. All three exist to measure agreement
between two *independent* channels. Deriving the breathing signal from the heart and
then feeding it back makes coherence the heart correlated with itself, which reads
artificially high and self-confirms.

The visible consequence, which is correct rather than a defect: **when EDR is
driving, Breath Rate shows a number while coherence, CBI, and Resonate's pace
detection stay unavailable.** `ResonateView.swift:92` guards on `tick.breathHz`, so
Resonate goes quiet exactly as it does today when ACC is out.

`breathBPM` non-nil while `breathHz` is nil is a deliberate asymmetry. It carries a
comment saying so, because it otherwise reads as an oversight and invites a "fix"
that would silently break the three metrics above.

### Persistence

`HRVSample` gains `var breathSourceRaw: Int?`. It is a plain `@Model` with all-optional
attributes and no `VersionedSchema`, so a new optional attribute gets SwiftData's
automatic lightweight migration. `MetricsHistoryPoint` gains a matching
`breathSource: BreathSource?`, populated from both the `MetricsTick` and `HRVSample`
initialisers.

Without this, past-day and Track charts silently mix measured and estimated readings
with no way to tell them apart.

## 5 · Chart

`MetricChartCard` gains one optional closure:

```swift
let isEstimated: ((MetricsHistoryPoint) -> Bool)?   // default nil
```

`ChartPoint` gains `estimated: Bool`; a bucket is estimated when *strictly more than
half* its samples are, so an even split resolves to measured. The flag folds into the
existing segment key, so a change of source starts a new
`LineMark` series and the dashed style cannot bleed across the boundary.

Estimated runs render dashed with hollow point symbols. A caption appears beneath the
subtitle only while estimated points are inside the visible window:

> estimated from heart rhythm — the strap couldn't see your breathing

Only `breathRateCard` passes the closure. The other nine cards are untouched, and the
parameter defaults to nil so their call sites do not change.

## 6 · PMDWatchdogPolicy

`ACCWatchdogPolicy` is renamed `PMDWatchdogPolicy` — it now governs both PMD streams,
not just ACC. `decide` gains a `timeSinceLastRRSample` parameter, and `Action` gains
two cases.

| condition | action |
|---|---|
| not connected, or in standby | `keepWaiting` |
| RR not flowing | `keepWaiting` — the link itself is down; reconnect owns it |
| ACC silent past threshold, ECG flowing | `retryACCStart` |
| ACC **and** ECG silent past threshold, RR flowing | `retryBothPMD` *(new)* |
| retry budget exhausted, stall persists | `slowRetry` *(new)* |

`retryBothPMD` is the branch that would have caught the 2026-08-07 outage: RR proves
the link is alive, so silence on both PMD streams is a PMD-level stall rather than a
connection problem, and both start commands get reissued.

`slowRetry` replaces `giveUp`. The watchdog task is no longer cancelled at
`BLEService.swift:638`; it stays alive for the session and retries every 60 s while
the stall persists. `lastError` is still set on first exhaustion so the UI can
surface it, and is cleared on recovery in `noteACCSampleReceived`.

`BLEService` tracks `lastRRSampleAt` alongside the existing `lastECGSampleAt` and
`lastACCSampleAt`, stamped where RR frames are parsed.

## 7 · Testing

The load-bearing test lives in `MetricsEngineTests`:

> ACC unavailable + healthy RR ⇒ `breathBPM` non-nil, `breathSource == .heart`, and
> `breathHz`, `coherence`, `cbi` all nil.

That is the anti-circularity invariant from section 4. If a future change wires EDR
into coherence, this fails.

**`SpectralPeakTests`** — a clean synthetic peak is found; a monotonically decaying
spectrum yields nil rather than the lowest bin; a candidate at the accept-band edge
still has both neighbours available from the search band; parabolic refinement lands
within a fraction of a bin.

**`EDRComputeTests`** — synthetic tachograms modulated at 12, 18 and 24 br/min are
recovered within one bin; a pure 0.1 Hz Mayer oscillation with no respiratory
component yields **nil, not 6 br/min**; fewer than `minBeats` yields nil.

**`BreathingComputeTests`** — modulation present on X only is recovered (the
rotated-strap case); a Z-dominant signal returns the same answer as before the
three-axis change; resolution at `nperseg` 8192 is measurably finer against a
synthetic of known rate; a buffer shorter than `minAccBreath` yields nil.

**`WelchPSDSegmentCountTests`** — a 16384-sample buffer at `nperseg` 8192 averages 3
segments, not 1. This is the assumption the resolution change rests on, and it is a
property of `welchPSD`'s loop bounds rather than of anything in `BreathingCompute`,
so it deserves its own test rather than being assumed.

**`BLETests`** — the two new policy branches, plus `slowRetry` re-arming instead of
cancelling. The existing `ACCWatchdogPolicy` tests need updating for the rename and
the new parameter.

## Risks

- **Warm-up is user-visible.** First breath reading moves from ~6 s to ~20 s after
  strap-on. Accepted: a reading quantised to 11.7 br/min bins is worse than no
  reading.
- **`nperseg` 8192 shifts historical comparability.** Readings recorded before this
  change used coarser bins.
- **The ACC buffers grow 12000 → 16384 samples**, so one estimate now spans 82 s
  rather than 60 s. Slower to reflect a deliberate change in breathing.
  `CoherenceCompute` is explicitly pinned to the last 12000 samples so it does not
  inherit this; any *other* future consumer of `snapshot.accZ` must make the same
  choice consciously.
- **Three-axis cost.** Worst case is three Welch transforms per 2 s tick, incurred
  only when Z alone fails. If profiling shows this is too heavy, the Z-first ordering
  already bounds the common case to today's cost.
- **The stale-buffer flat line is not fixed here.** A mid-session ACC death still
  yields a frozen value rather than a gap, because the buffers carry no timestamps.
  The watchdog now recovers from that within 60 s, which bounds the exposure, but
  ageing the buffers out is deliberately left as separate work.
