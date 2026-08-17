# Five-section scores + transparent overall — spec

Owner ask (2026-08-16): a 0–100 per section — Ready / Mobilized / Sustained / Cost / Recovery — an overall composed from them, and the critical metrics on the session chart. Grounded in docs/research/2026-08-16-exercise-measurement-redesign.md.

## ⓪ Ready — exists, unchanged
`ReadinessScore`: percentile of beforeRMSSD / beforeHR / beforeDC vs own last ≤60 pre-session windows, interpolated 10th–90th. **Context only — never enters the overall** (RCT evidence is prospective-only; report §1). Later guard: stillness check on the before-window (open defect: walking-in contamination).

## ① Mobilized — NEW score
How fast the system rose to the load. Basis: HR on-kinetics; trained t½ ≈ 24 s, untrained ≈ 47 s (PMC4687158).
- `tHalf` = seconds from session start to first sustained crossing of resting + 0.5 × (sessionPeak − resting). Sustained = stays above for ≥60 s.
- **Score = ramp(tHalf, best 30 s, worst 120 s).**
- Gates: only workout/mixed class; peak ≥ 40% HRR; a detected monotonic onset ≥2 min (else absent, not estimated).
- Needs: downsampled HR series stored (`sessionSeriesBlob`, report slice 7). Until then: absent.

## ② Sustained — NEW score
How well the body held the work — autonomic stability, not effort volume.
- **(a) α1 stability (60%)**: compare mean DFA-α1 of the second half vs first half *at matched HR zone minutes*. declinePct = max(0, (α1₁ − α1₂)/α1₁ × 100). Sub = ramp(declinePct, best 0%, worst 25%). Validated: α1 down-drift at constant HR = fatigue/durability marker (EJSS 2024, Gronwald/Rogers 2022). Artifact gate ≥5% suppresses.
- **(b) Zone–domain agreement (40%)**: fraction of work minutes where the HR zone band and the α1 domain agree (both moderate / both hard). Sub = 100 × fraction. Disagreement = strap, ceiling, or fatigue — a real signal (report §1).
- **Score = 0.6a + 0.4b**, present only if both computable. Readiness stays OUT (contextualize, don't gate) — shown beside it as "on a 41-readiness day" annotation instead.
- Needs: series blob + `artifactPct`. Until then: absent.

## ③ Cost — exists, renamed
`ExerciseSuppression.economyScore`: brakePerBeat anchored 0.04 ms/beat → 100, 0.20 → 0. Non-positive → not scored ("vagal tone held"). No change; the section headline it already has.

## ④ Recovery — REBUILT as two named sub-scores
- **(a) Pulse return (existing)**: HRR60 anchored 10 bpm → 0, 40 → 100, ending-intensity gate kept.
- **(b) Calm return (NEW, owner's idea — good one)**: afterRMSSD vs the MORNING anchor, not the contaminated pre-window: `settle = clamp(afterRMSSD / morningRMSSD, 0, 1) × 100`, morningRMSSD from that day's DailyAnchor (fallback: 7-day anchor median; absent if no anchor). "Back to your morning calm" is the honest 'normal'.
- **Score = mean of present subs**; captions name them ("pulse back 34 bpm · calm at 82% of your morning").
- Replaces BounceBackIndex's dead decoupling term (report: SPLIT verdict).

## Overall session score — transparent or nothing
Weighted over PRESENT performance sections only (Ready excluded): **Recovery .40, Sustained .30, Cost .20, Mobilized .10**, renormalized. Require ≥2 present else no headline (current rule kept). The detail view prints the arithmetic: "72 = 40% recovery(81) + 30% sustained(66) + …". No crown until ≥3 components. This honors the report's "no opaque composites" by making it checkable, while giving the owner the single number asked for.

## Chart
SessionTimelineChart gains markers: tHalf point ("mobilized in 41 s"), peak, HRR60 drop bracket at session end, α1 domain band underlay, and the after-window RMSSD vs morning-anchor line.

## Order
1. Recovery rebuild (needs only DailyAnchor join) + overall rewire — ships now.
2. Series blob + artifactPct fields (backfill bump) → Mobilized + Sustained.
3. Chart markers.
