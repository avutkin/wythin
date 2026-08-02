# Current State — accuracy and progressive disclosure

**Date:** 2026-08-02
**Status:** Design, approved in brainstorming. Not yet planned or implemented.

## The problem

The Current State widget does not represent the person it is describing. Three
distinct failures, in the user's own words: the state is sometimes **just
wrong**, it is often **right-ish but generic**, and it is **behind reality**.
Activity-blindness was explicitly *not* among the complaints.

## Why it fails

### 1. The prompt contradicts itself

The nine states are defined by deviation — "Inner Noise ↑↑", "HRV/DC ↓↓", "all
metrics near baseline", "DFA alpha-1 ~1.0". Every one of those is a statement
*relative to this person's normal*. The same prompt then forbids exactly that:

> NEVER compare to an average, a norm, a 'usual' value or a 'typical' day. You
> do NOT have one and must not invent one.

and `LiveStateTrendCompute` deliberately withholds `dayMean` from the payload.
So the model must decide whether inner noise is "↑↑" from ten minutes of
absolute numbers with no reference point. It cannot, and falls back on
population priors from pretraining. For a user whose resting RMSSD sits near
30 ms, that systematically reads low.

This is the root cause of "just wrong", and it is structural rather than a
matter of wording.

### 2. Classification is a side effect of writing prose

Nothing computes the state. The model picks `state_key` while composing the
reply, so identical physiology can yield different states on consecutive calls,
and nothing ties one 5-minute refresh to the next.

### 3. The lag is architectural

A 10-minute window refreshed at most every 5 minutes is up to 15 minutes stale.
Nothing renders at all without the network — the widget shows "Gathering data…"
however good the reading is.

### 4. No ground truth exists

The user's felt state has never been recorded, so the widget's accuracy has
never been measured and cannot be improved except by guessing.

### 5. The balance bar is population-referenced

`CurrentStateCard` calls `AutonomicCompute.compute(tick:baseline: nil)`, putting
PNS on the absolute curve where RMSSD 40 → 0.50. At this user's levels that bar
reads sympathetic-dominant almost always, by construction.

## Approach

Chosen: **demote the model to narrator.** Compute the state on-device against a
personal baseline; the LLM is handed the finished z-scores and writes only
prose. This is the division that already works for Morning Read, and it is why
that number is stable and trusted.

Rejected: giving the model a baseline while it still classifies (leaves the
instability and the lag, and means rewriting the prompt twice); and fitting the
state model to check-in data (needs weeks of check-ins that do not exist yet,
and would overfit badly on a handful — the trap `BaselinePrior` exists to
avoid). The check-in ships here so that work becomes possible later.

## Design

### 1. Live baseline

`DailyRollup` currently stores one mean per metric per day. Extend it to also
store, per metric, the **within-day standard deviation** and the count behind
it.

This matters more than it looks. The obvious implementation — z-scoring the
current 10-minute value against the distribution of daily means — is wrong.
The spread of daily means is *between-day* variance; a 10-minute window varies
by *within-day* variance, which is far larger. Dividing by the smaller number
inflates every z, so ordinary fluctuation would read as "well above your usual"
all day. The widget would become confidently wrong in a new way.

The baseline for a metric is therefore:

- **centre** — mean of daily means across the window
- **spread** — √(sample-count-weighted mean of within-day variances), the
  typical minute-to-minute spread of a normal day
- **z** — `BaselineStat.z(value, prior:)`, reused unchanged

Reusing `BaselineStat` brings the prior-blending and prediction-widening
already written and tested for the anchor score. It is what stops the first few
days producing wild numbers, and it degrades to the prior alone at n = 1 with no
special case.

Window: `AnchorBaseline.windowDays` (60), for consistency with the existing
baseline.

New `BaselinePrior` constants are needed for the live metrics. They are
literature-informed guesses and must be marked uncalibrated in the same way the
anchor's are.

Cache handling is already solved: bump `TrackCache.rollupComputeVersion` from 2
to 3. Existing rollups are discarded and recomputed from stored samples. No
migration code and no partially-populated records.

**The baseline is all-day**, so it includes exercise and meditation. "Your
usual" therefore means your usual waking life, not your usual rest. This is
deliberate for a widget answering "how am I right now", and it means a hard
workout reads as genuinely elevated rather than being excused. Accepted, given
activity-blindness was not a reported problem.

### 2. State classifier

Three axes, each a weighted sum of z-scores:

| Axis | Inputs |
|---|---|
| Energy | `meanBPM`, `rmssd`, `rcmse` |
| Tension | `stressBalance` (SNS share), `pip` |
| Recovery | `rsaMs`, `dc`, `vti` |

The axis triple maps to one of the existing nine states through an explicit
rule table. The nine states, their names and their meanings are unchanged —
only the thing that chooses between them changes.

**Contribution.** Each metric's signed contribution is `weight × z`. This is
what ranks the WHY bullets and sizes their impact bars. It is the actual pull
the metric had on the state, not the model's guess at what mattered.

**Hysteresis.** A newly-computed state must persist across N consecutive
evaluations before the displayed state changes; N starts at 3. Without this the
label flickers between neighbouring states while the person feels unchanged.

**Two inputs overlap and the weights must account for it.** `stressBalance` is
derived from RMSSD (via `AutonomicCompute.balance`), and RMSSD is also an input
to the Energy axis, so the two axes are not independent. Z-scoring is not the
problem — `stressBalance` is compared against the person's own distribution of
the same derived quantity, so the absolute map inside it cancels out. The issue
is double-weighting one measurement, and the axis weights must be set knowing
that.

**Weak calls.** When every |z| is small the state is `stable_neutral` and the
impact bars are all short. This is honest and visible, where the current
version hides a weak call behind equally confident prose.

**Window.** A rolling 10 minutes, recomputed every tick.

**Cadence.** `LiveStateTrendCompute.summarize` requires ≥30 points, a figure
that assumes the 2 s foreground tick. At the 30 s background tick a 10-minute
window holds 20 points and the function refuses every time — its own doc
comment warns callers to lower the threshold and `LiveStateStore` does not.
This is the same class of defect as the anchor cadence bug: a threshold
expressed in one unit that does not hold at the other rate.

The fix is to express the minimum as **coverage of the window rather than a
raw count**: infer the observed sample interval from the data, and require the
window to be at least 60% populated at that interval. That holds at 2 s and at
30 s without either rate being named in the constant.

### 3. Local copy

A table keyed by state, following the existing `NudgeCopy` pattern: display
names and a feeling phrase per state ("Sharp and settled", "Revved and hard to
settle", "Flat and far away").

Variety must be **deterministic** — selected by a stable hash of state and day,
never randomly — or the phrase would change on every view re-render.

### 4. Narration

The LLM receives the chosen state, per-metric z-scores and contributions, and
the baseline's size and provisional flag. It writes:

- the **why-clause** completing the collapsed sentence
- the ranked **WHY** bullets, which may cite specific numbers
- the **RIGHT NOW** line

Prompt changes: delete the "NEVER compare to a norm" instruction, which is now
false — norms are supplied. Add a prohibition on choosing or contradicting the
state, and on inventing a metric ordering; the ranking is given.

**State-binding.** The why-clause is bound to the state instance that produced
it:

1. Name and feeling phrase render immediately and locally, always.
   "Sharp and settled" alone is a complete line.
2. The why-clause is appended only when narration for *this* state has arrived.
   On any state change it is dropped instantly.
3. A state change bypasses the 5-minute throttle and requests narration
   immediately, with a 60-second floor so flapping cannot hammer the API.

This is what prevents a fresh label sitting above a stale explanation, which
would be worse than either alone.

### 5. Layout

Three sections in one card.

**Current State** (collapsible)
- `CURRENT STATE` tag
- state name
- one sentence: feeling first, then why

**WHY** (revealed on tap; the only thing the drop-down holds)
- bold heading, not a dim label
- bulleted, ranked by contribution, strongest first
- an impact bar per bullet showing that metric's pull
- specific numbers belong here
- bullet count follows the data — every metric whose |contribution| clears a
  threshold (starting at 0.25, i.e. a quarter of an axis-weighted SD),
  typically three to six. A quiet day gets a short list, and that shortness is
  information. At least one bullet always shows, even on a flat window.

**RIGHT NOW** (always visible, never inside the drop-down)
- unchanged in content; it simply does not move when the state expands

**DOES THIS MATCH?** (always visible)
- four scales: focus, anxiety, energy, mood

Expansion state persists via `@AppStorage("currentStateExpanded")`, mirroring
`dayPotentialExpanded`.

The whole collapsed row is the tap target, not just the chevron.

Voice is plain ("Sharp and settled"), not hedged. The hedge lives in the design
instead of the copy: the scales underneath are what ask whether it landed.

### 6. Check-in

New SwiftData model `FeltStateLog`: timestamp, focus, anxiety, energy, mood, and
the state key displayed at the time.

Stored locally and synced with everything else. It drives nothing in this
change — its only job is to accumulate the ground truth that a later calibration
pass needs.

### 7. Cleanup

- `PolyvagalState.infer` is computed from every tick at `LiveView.swift:170`,
  passed into `CurrentStateCard`, and never read; `causeSection` is defined and
  never called. Remove the dead path rather than build a fourth classifier
  beside it.
- `CurrentStateCard` should receive a real baseline RMSSD from the live
  baseline instead of `nil`, so the balance bar stops being population-
  referenced.

## Error handling

| Condition | Behaviour |
|---|---|
| Few days of rollups | Prior-dominated z, same graceful degradation as the anchor score. Surface that the range is still forming. |
| Too few points in window | Hold the last state; mark it stale rather than blanking. |
| Network down or narration fails | Name and feeling phrase render as normal; no why-clause, no bullets. The state is never withheld. |
| State changes | Why-clause and bullets cleared immediately, regardless of fetch outcome. |

## Testing

Pure units, no context or environment needed:

- pooled within-day SD, including the weighting and the n = 1 case
- axis computation from z-scores
- the state rule table across the nine states
- hysteresis: no flip on one noisy evaluation, flips after a sustained change
- contribution ranking and threshold-based bullet count
- copy selection determinism — same state and day yields the same phrase
- state-binding: why-clause cleared on state change, immediate refetch, 60 s
  floor honoured

Per the anchor cadence lesson, every window rule is tested at **both** 2 s and
30 s sample spacing.

## Out of scope

- Fitting the state model to check-in data. Needs weeks of check-ins; this
  change is what starts collecting them.
- Sending activity context to the narration. Not a reported problem.
- Recalibrating `AnchorThresholds.breathRange`, which rejects resonance
  breathing. Real, tracked separately, and unrelated to this widget.

## Known-uncalibrated

- `BaselinePrior` constants for live metrics — literature-informed, not this
  user's. Recalibrate once ~30 days of rollups with SD exist.
- Axis weights — reasoned extension, not validated, exactly as
  `PotentialScore`'s are. If the composite ever disagrees with plain lnRMSSD
  inexplicably, plain lnRMSSD is the one to trust.
- State boundary thresholds and the hysteresis count — first guesses, to be
  tuned against check-in data once there is any.
