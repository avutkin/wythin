# Recovery Kinetics Model — Design

**Date:** 2026-08-20
**Status:** Design, awaiting review
**Scope:** How a session's recovery is measured, layered, scored and compared over time. Supersedes
the single-number recovery axis in `2026-07-31-exercise-response-model-design.md` §5.2.

---

## 1. Problem

The app measures recovery well and reports it badly.

A recorded pickleball session had heart rate back within four minutes and a vagal brake still short
of halfway at thirty-four. The screen showed **RECOVERED 0 / 100** above a chart of that fast
return. Three separate faults produced it, and only the first has been fixed:

1. **One checkpoint became the whole section.** Fixed — `RecoveryIndex` now composes several,
   renormalises over those present, and refuses to score below two.
2. **No expectation was ever stated.** `>34 min` is unremarkable for a heavy session. It reads as
   failure only because nothing on screen said what to expect at that load.
3. **Two different recoveries were collapsed into one word.** Cardiovascular load coming down and
   parasympathetic control returning are different processes on different timescales. A single
   "recovered" number reports whichever one it happened to be built from.

This model addresses 2 and 3.

## 2. Non-goals

- **Physical recovery is not measured.** Glycogen, muscle damage and connective-tissue repair are
  invisible to an ECG. The model names this layer and leaves it empty (§5); it never lets autonomic
  recovery stand in for readiness to train.
- **No population verdicts.** Only HRR60 has defensible norms, and only under conditions field
  sessions do not meet (§8).
- **No cardiac risk claims.** DC's clinical thresholds come from 24-hour Holter recordings in
  post-MI patients. They must never appear beside a post-session DC reading.

## 3. The two recoveries

The distinction the model is built on:

| | Question | Signals | Timescale |
|---|---|---|---|
| **Cardiovascular** | How fast did circulatory load come down? | heart-rate kinetics | seconds to minutes |
| **Neural** | How fast did parasympathetic cardiac control return? | DC, RMSSD, RSA, DFA α1 | minutes to hours |

They diverge, and the divergence is the finding. Heart rate home at eight minutes with vagal
regulation still suppressed at twenty is a real and interesting state; one blended number cannot
express it.

**The split is by window × signal, not by signal alone.** The first thirty seconds of heart-rate
fall *is* vagal reactivation (Imai et al. 1994); later heart-rate fall reflects sympathetic
withdrawal. Filing "HR = cardiovascular, HRV = neural" wholesale would put the best available vagal
measurement in the wrong column.

## 4. The four windows

| Window | Mechanism | Measures | Layer | Built |
|---|---|---|---|---|
| **0–30 s** | vagal reactivation begins | HRR30, T30 | neural | T30 ✓ |
| **30 s–2 min** | sympathetic withdrawal dominates | HRR60, HRR120, HRRτ | cardiovascular | HRR60 ✓ |
| **2–10 min** | vagal indices reappear, respiratory coupling returns | DC rebound, RMSSD reactivation %, RSA return | neural | RMSSD % ✓ |
| **10–30 min+** | approach to baseline, or visible failure to | time-to-halfway (both channels), α1 recrossing 0.75, time-to-baseline, stability | both | both halfway times ✓ |

### 4.1 Measure definitions

- **HRR30 / HRR60 / HRR120** — bpm below end-of-session HR at +30/60/120 s, linearly interpolated
  between bracketing samples, `nil` when no sample falls within ±20 s of the mark.
- **T30** — negative reciprocal of the slope of ln(HR) on time over the first 30 s. Smaller is
  faster.
- **HRRτ** — time constant of a mono-exponential fit to HR decay over 0–6 min. Reported, not
  scored: it is highly correlated with T30 and HRR60 and would be a third vote for one measurement.
- **DC rebound** — DC at +10 min as a fraction of the pre-session level.
- **RMSSD reactivation %** — `afterRMSSD ÷ beforeRMSSD`, capped at complete.
- **RSA return** — `rsaMs` at +10 min as a fraction of pre. Only valid in stillness; gated by §7.
- **α1 recrossing** — minutes until DFA α1 climbs back through 0.75, i.e. the system has left the
  heavy domain.
- **Time-to-halfway** — minutes to climb (DC) or fall (HR) halfway from the session extreme back
  toward the pre-session level, held for 5 minutes. One implementation,
  `RecoveryTiming.crossing(_:target:direction:)`, for both channels. ✓
- **Time-to-baseline** — first sustained (≥5 min) return of lnRMSSD to within 0.5 SD of the
  pre-session window. Reported as a bound when not reached.

## 5. The Recovery Profile

Three layers, always all three shown:

```
RECOVERY PROFILE
Cardiovascular    92%
Neural            64%
Physical           —     not measurable from ECG
Stability         71%
```

- **Cardiovascular %** — `(HRpeak − HR@10min) / (HRpeak − HRrest)`, clamped to 0–100.
- **Neural %** — `(DC@10min − DCtrough) / (DCpre − DCtrough)`, clamped. RMSSD reactivation is shown
  beside it as a second reading of the same layer, never averaged into it.
- **Physical** — always `—`. The layer exists on screen precisely so that a person reading
  "Cardiovascular 92%" after heavy lifting is not invited to conclude they are ready to train.
- **Stability** — did it come back and *stay* back? The share of post-session samples that hold at
  or better than the best level reached so far: for heart rate, `HR ≤ 1.05 × running minimum`; for
  DC, `DC ≥ 0.95 × running maximum`; the two averaged. A trace that returns and then bounces scores
  lower than one that returns and settles, at the same halfway time.

## 6. The hero: Time to Stable Recovery

**The headline is a time, not a score.** "Vagal Rebound 11.2 min" is a kinetic property of the
person; "DC 8.6 ms" is a reading off an instrument. The 0–100 composite stays, one level down, as
the section score.

**Definition.** The first minute *t* after session end at which **both** conditions hold, and
continue to hold for 5 minutes:

- **Cardiovascular:** `HR ≤ restingHR × 1.10`
- **Neural:** DC at or above the halfway bar (`trough + (pre − trough) / 2`)

Outcome takes the existing three-case shape — `reached` / `notReached(observed)` / `notObserved` —
so it reuses `RecoveryTiming.Outcome` and its crossing rule.

### 6.1 The bound is the common case, and must carry information

Requiring both channels means this resolves *less* often than either alone. On a heavy session it
will frequently end as a bound. A bare `>34 min` is what made the original screen read as a
failure, so an unresolved hero is never shown alone:

```
RECOVERY
> 34 min          still recalibrating when the recording ended
                  typical for a heavy session: 15–45 min

Heart-rate return      4.1 min        ✓ within 10% of resting
Vagal rebound        > 34 min         held below halfway
```

The expected range comes from §8 while the person has no history, and from their own matched
sessions once they do. A bound stated against an expectation is a finding; a bound stated alone is
an error message.

## 7. Gates

Each gate marks a reading as *not comparable* rather than discarding it. An annotated reading still
appears; it just does not enter the personal reference set.

- **Ending intensity** — HRR is meaningless if the session ended near resting. Already implemented
  as `HeartRateRecovery.endedHardEnough`.
- **Active vs passive recovery — new, and the largest uncontrolled variable.** Walking off the
  court keeps HR elevated and flattens HRR60; sitting down steepens it. This moves HRR more than
  fitness does. Detect from `motion` over the first two minutes after the end: above the session's
  own break floor for more than half the window ⇒ **active recovery**. Annotate, and keep active
  and passive recoveries in separate reference sets.
- **Posture — new.** DC and RMSSD are strongly posture-dependent; a vagal rebound measured seated
  and one measured standing are not the same measurement. `PostureCompute` already exists. Where the
  recovery-window posture differs from the pre-session window, annotate and exclude from the
  personal reference. Without this, load-conditioning spends its power on variance that is only
  chair-versus-feet.

## 8. Reference ranges

**What is defensible.** HRR60 has real norms: <12 bpm at one minute is the classic abnormal cutoff
(Cole et al., *NEJM* 1999), 20–30 healthy, 30–50 well-trained — all from symptom-limited maximal
treadmill tests with standardized cooldown. Shown as a band to sit inside, never as a verdict, and
never without the caveat that a field session is not that test.

**Two ways the norm misleads, both stated on screen where the number appears:**

- HRR is **not monotonic in load**. The absolute drop grows with peak intensity, then flattens or
  reverses at very high intensity as sympathetic drive persists. "Harder session ⇒ worse HRR" is
  wrong at both ends of the range.
- Recovery mode dominates (§7).

**What is not defensible.** DC's clinical thresholds (≤4.5 ms high risk, >5.5 low risk) are
24-hour Holter values from post-MI cohorts. Displaying them next to a ten-minute post-exercise DC
would present a cardiac risk verdict derived from a game of pickleball. Prohibited.

**Orienting expectations** — used only until the person has matched history, and always labelled as
typical-for-load rather than as a target. From the post-exercise reactivation literature (Stanley,
Peake & Buchheit, *Sports Medicine* 2013):

| Load band | HR halfway | Vagal halfway | Vagal to baseline |
|---|---|---|---|
| Moderate — below threshold | 1–3 min | 5–15 min | under ~1–2 h |
| Heavy — at or above threshold | 2–5 min | 15–45 min | ~24 h |
| Severe — α1 < 0.5, intervals to exhaustion | 3–8 min | often beyond the recording | 24–48 h+ |

### 8.1 Load bands

- **Warm:** quartiles of the person's own `exerciseLoad` across the last 90 days of the same
  activity class, requiring ≥5 sessions in a band before it is used.
- **Cold start:** the α1 intensity-domain split already computed per session
  (`domainModerateSec` / `domainHeavySec` / `domainSevereSec`) — whichever domain holds the most
  time names the band. Available on the first session, needs no history.

Every checkpoint is scored against the person's own distribution **within its load band**. Without
that conditioning, recovery is load with the sign flipped and the profile collapses to one line.

## 9. Adaptation: the same stimulus, months apart

The claim worth making is not "your HRV rose 7%" but "you recovered 42% faster from the same
physiological stress than you did four weeks ago".

**Matched stimulus** = same activity subtype **and** same load band **and** peak HR within ±5 bpm
**and** same recovery mode (§7). Report the change in Time to Stable Recovery and in each channel
time against the mean of the last *n* matched sessions, always printing *n*.

Below five matched sessions no adaptation claim is made — the between-session variance in these
kinetics is large enough that a two-session comparison is noise with a percentage sign on it.

## 10. Intervention engine

Tag a post-session intervention (slow breathing, walking, NSDR, cold exposure), then compare
recovery kinetics with and without it at matched stimulus.

Three guardrails, without which this manufactures findings:

1. **The tag is chosen before the recovery window ends.** Labelling a session "slow breathing"
   after seeing a fast rebound is how an app discovers that whatever you tried last week works.
2. **Minimum five matched pairs**, and the effect is reported as a paired difference with an
   interval — never a single trial and a verdict.
3. **The comparison names its own weakness.** Regression to the mean pushes a session that started
   unusually suppressed toward a large apparent improvement; the copy says so where the effect is
   shown.

## 11. Naming

One name per measure, per the app's existing registry rule. Consumer names report the kinetic
property, not the instrument:

| Shown | Not shown |
|---|---|
| Vagal Rebound — 11.2 min | DC — 8.6 ms |
| Heart-rate Return — 4.1 min | HRR60 — 34 bpm *(as a headline; fine as a checkpoint)* |
| Recovery Capacity | "vagal tone" as a product frame |

"Vagal tone" stays as the name of the DC card, where it means one specific measurement. It does not
become the name of the product concept, where it would spread across four different signals.

## 12. What this adds to what exists

**Already built:** HRR60, T30, RMSSD reactivation ratio, DC time-to-halfway, HR time-to-halfway, the
weighted `RecoveryIndex` composite with renormalisation and a two-checkpoint minimum, a one-hour
recovery window shared by the score and both charts, and one crossing rule for both channels.

**This model adds:** HRR30 / HRR120 / HRRτ · RSA return · α1 recrossing · time-to-baseline · Time to
Stable Recovery · the three-layer profile with stability · load bands and per-band personal
conditioning · active/passive and posture gates · matched-stimulus adaptation · the intervention
engine.

## 13. Open questions

- **Recovery-mode detection threshold.** "Above the break floor for more than half of the first two
  minutes" is a first guess and needs checking against real sessions where the mode is known.
- **Stability's tolerance bands** (1.05 / 0.95) are chosen to reject sampling noise, not derived.
  They should be set from the observed noise floor of each signal.
- **Where the profile lives.** It could replace the ③ RECOVERED headline or sit beneath it. This
  spec does not decide the layout.
