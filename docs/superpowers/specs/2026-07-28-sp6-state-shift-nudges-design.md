# SP6 — State-shift nudges — Design

**Goal:** Watch the live metric stream on-device and, a few times a day at most, either suggest an evidence-backed intervention when the user's regulatory state has meaningfully deteriorated, or tell them — quietly — that they are in a rare clear window worth spending on their hardest task.

**Status:** Draft, revision 2 — realigned against the primary literature. Revision 1's trigger set is superseded; see §3.6 for what changed and why.

**Depends on:** the anchor baseline (`AnchorBaseline` / `DailyAnchor` / `AnchorDetector`), `LiveStateTrendCompute`, `AutonomicCompute`, and the continuous background tick loop in `AppEnvironment`. No server change. No new sync.

**Scope:** iOS app only. Phase 1 is a shadow-mode engine with no user-visible output; Phase 2 enables delivery after thresholds are tuned against real data.

---

## 1. Why

The app already classifies nervous-system state and writes a "RIGHT NOW" recommendation — but only while the user is looking at the Live tab. The physiologically interesting moments happen when the app is closed. Nothing surfaces them.

The metric stream is already continuous. `AppEnvironment.swift:302-401` computes a tick every 2 s in foreground and every 30 s in background, persisting every one to SwiftData, and the app stays alive backgrounded on the `bluetooth-central` mode while the strap streams. Everything needed to detect a state shift is already being computed — it is simply never read while the app is closed.

### Design decisions taken up front

| | |
|---|---|
| Detection | Deterministic on-device rules with templated copy. No LLM in either detection or wording. |
| Downshift target | A **menu**, not a prescription: an evidence-chosen primary plus alternates the user can pick by context. Six options (§5.1), four of which need no pacer work. |
| Movement target | `ActivityLogging.begin(type: .walk)` — a *live* activity, so the impact pipeline can report afterwards whether it helped. Same for every other option, which is what later makes per-user ranking possible. |
| Focus window | **Silent.** No push. A past-tense card waiting in-app on next open — see §6. |
| Budget | ≤3 downshift/day, ≥90 min apart, ≤1 focus/day, quiet hours 22:00–07:00, suppressed during a logged activity, during BLE `.standby`, and below 7 baseline anchors. |
| Rollout | Shadow mode first. |

### The governing constraint

**A metric earns a place in a trigger only if the literature supports it changing on the timescale the trigger claims, and the paired intervention targets the mechanism the metric measures.** Applying that test in §3 removed two of revision 1's five triggers and changed three of the five interventions.

---

## 2. Code findings that constrain the design

Each confirmed by reading the source.

### 2.1 Stress Balance is algebraically RMSSD

`AutonomicCompute.vagalIndex` (`Metrics/AutonomicCompute.swift:77-83`) returns nil only when RMSSD is nil or ≤ 0, so the LF/HF fallback at `:64` is unreachable for any real tick. With `baselineRmssd: nil` (`UI/Live/MetricsChartsView.swift:1246-1248`) the dial reduces to `100 × 40/(RMSSD + 40)`.

The dial's RefLines and the Energy Reserve RefLines, set independently, agree exactly:

| Dial (`MetricsChartsView.swift:1229-1231`) | RMSSD | Energy Reserve RefLine (`:1047-1049`) |
|---|---|---|
| 45 "parasympathetic" | 48.9 ms | above the 40 "healthy" line |
| 50 "flow · balanced" | 40.0 ms | **exactly** the 40 line |
| 65 "sympathetic" | 21.5 ms | ≈ the 20 "low" line |

Good mutual validation — but it means the dial and RMSSD cannot occupy two trigger slots.

### 2.2 The trend engine cannot run in the background — blocking

`LiveStateTrendCompute.minimumPoints = 30`, commented "≈2 minutes at 2 s/tick", but the default window is 10 minutes (`Metrics/LiveStateTrendCompute.swift:62,67`). At the 30 s background cadence a 10-minute window holds 20 points, so `summarize` returns nil at `:70` — forever. `minimumPoints` must become a parameter with the current value as default.

### 2.3 There is no in-memory background window at all

Both `latestTick` and `tickHistory.append` sit inside `if inForeground` (`App/AppEnvironment.swift:367-369`). A background engine can read neither. It needs its own buffer — §4.

### 2.4 Slow metrics carry ~20 minutes of latency

`rrBuf` holds 1200 RR intervals ≈ 20 min at rest (`BLE/DataBuffer.swift:63-65`), and `MetricsEngine.compute` runs RMSSD, SDNN, VTI, PIP, DC, DFA α1, RCMSE and the power bands over the whole buffer.

| Metric | Source window | Effective lag |
|---|---|---|
| `meanBPM` | median of last 8 sensor samples (`HeartRateCompute.swift:16`) | ~5 s |
| `motion`, `breathBPM` | ACC / accZ windows | ~30 s |
| `rsaMs` | last 90 RR (`MetricsEngine.swift:110`) | ~45 s |
| `rmssd`, `pip`, `dc`, `dfa1`, `vti`, `rcmse`, `coherence` | full RR buffer | **~7–20 min** |

Consequences: sustain windows buy almost no statistical independence (two ticks 30 s apart share ~96 % of their RR input); a trend window must be ≥ 25 min for its endpoints to be independent; and PIP/DC volatility is too smoothed to serve as a stability test. Only HR and breathing rate move fast enough for that.

### 2.5 Smaller confirmed constraints

- `ResonateView` hardcodes `targetBPM` and `iePreset` as `@State` with no initialiser (`UI/Resonate/ResonateView.swift:6-7`). Opening Resonance at a chosen rate is **not currently possible**.
- Zero `UserNotifications` infrastructure, no entitlements file, no `AppDelegate`, only `bluetooth-central` in `Info.plist:15-18`.
- DC is only recorded on anchors ≥ `preferredMinSec` 300 s (`AnchorDetector.swift:17,132`), so users with only short anchors have no DC baseline.

---

## 3. Evidence base

This section is the substance of revision 2. Each metric is assessed for **what it is validated to measure** and **on what timescale**, then each intervention for **what it is validated to change**.

### 3.1 What the metrics are actually validated for

| Metric | Validated as | Validated timescale | Verdict for nudges |
|---|---|---|---|
| **RMSSD / RSA / HF** (vagally-mediated HRV) | Cardiac vagal tone; correlates with prefrontal executive function and self-regulation (neurovisceral integration) | Minutes — responds within a single breathing session | ✅ **The acute state axis.** Use it. |
| **PIP** (heart rate fragmentation) | Sinus-node electrophysiologic dysfunction; tracks **age** and **coronary artery disease**; predicts cardiovascular events (MESA) | Years — a trait/structural marker | ❌ **Not an acute state marker.** See 3.2. |
| **DC** (deceleration capacity) | Post-infarction mortality, from **24-hour Holter** recordings | 24 hours minimum, interpreted over weeks | ⚠️ **Not a 30-minute marker.** See 3.3. |
| **DFA α1** | Exercise intensity / aerobic threshold; endurance fatigue; lowered by mental workload | Tens of minutes under sustained load | ⚠️ Supported for **fatigue/load**, not for "focus". |
| **HR** | Acute arousal | Seconds | ✅ Fast-path only. |
| **Motion / sedentary time** | Sedentary exposure; the target of activity-break trials | Continuous | ✅ Well-grounded. |

### 3.2 The finding that reshapes this spec: PIP is not what the app says it is

The app labels PIP "Inner Noise" and treats it as a **focus proxy** that should respond to breathing within minutes — `insights.py:235-236` describes it as "lower = smoother, more settled attention; higher = scattered/restless", and revision 1 built its headline trigger on it.

The primary literature does not support this. Costa & Goldberger introduced fragmentation specifically to quantify beat-to-beat dynamics that are **not** explained by autonomic regulation:

> "Vagal tone modulation changes the heart rate in a progressive way… In contrast, non-vagally mediated, short-term heart rate variability has a distinct dynamical signature."

Their analysis notes that fragmentation changes exceed "the shortest-term modulatory responsiveness of the vagal system," pointing to sinus-node electrophysiologic dysfunction rather than autonomic state. The follow-up literature is titled, in as many words, *"Heart rate fragmentation gives novel insights into **non-autonomic** mechanisms governing beat-to-beat control of the heart's rhythm."* Validation is against **age**, **coronary artery disease**, and cardiovascular events in MESA — not against mood, attention, or workload.

**Being fair to the existing framing:** there is one live thread — an exploratory 2025 line in *Applied Psychophysiology and Biofeedback* examining fragmentation as a marker of **allostatic load** and psychosocial stress reactivity in healthy adults. That is genuinely relevant, but allostatic load is a *cumulative* construct measured over weeks and months. It supports PIP as a slow burden indicator; it does not support a 30-minute trigger.

**Consequences for SP6:**

1. Revision 1's D1 (`inner_noise_rising`, PIP over 30 minutes → do slow breathing) is **withdrawn**. There is no mechanism by which five minutes of breathing would move a sinus-node fragmentation marker, and no evidence it tracks the state the copy claimed.
2. PIP is removed from F1's level conditions as a primary criterion.
3. PIP is **not deleted from the app.** It is repositioned as a slow indicator — a weekly/monthly trend on the morning anchor read, where the age/CAD/allostatic-load literature actually applies.

**This finding extends beyond SP6.** "Inner Noise" as a real-time focus proxy also appears in the live-state LLM prompt (`insights.py:132-138`, `:235-236`), the activity impact grid (`ActivityMetricsGrid.swift:54-55`), and the Live tile (`LiveView.swift:771`). Those are out of scope here, but the framing is inconsistent with the source literature in all of them and should be revisited. Flagged as open question 1.

### 3.3 DC over 30 minutes is an over-reach

Bauer et al. (*Lancet* 2006) established deceleration capacity on **24-hour Holter** recordings in a 1455-patient post-infarction cohort, validated in London and Oulu, where it outperformed LVEF and SDNN for mortality prediction (AUC 0.80 vs 0.67 and 0.69 in London). It is a strong marker — of 24-hour vagal capacity, prognostically.

Nothing in that validation licenses reading DC over a 30-minute window as a state signal. The app's own DC card already says so: *"Changes slowly — read it as a trend over days and weeks"* (`MetricsChartsView.swift:1117`). Revision 1's D2 contradicted the app's own copy, and the app's copy was right.

**Consequence:** D2 (`settling_fading`) is **withdrawn** as a trigger. DC stays where it belongs — the daily anchor and the multi-day trend. It is retained in F1 only as a *corroborating* condition against the person's own norm, not as a 30-minute slope.

### 3.4 What the interventions are actually validated to do

| Intervention | Evidence | What it changes | Best fit |
|---|---|---|---|
| **Resonance breathing ~6/min (0.1 Hz)** | Lehrer & Gevirtz; Laborde et al. 2022 (*Psychophysiology*) | Maximises RSA amplitude via baroreflex resonance; large LF-power increase | Vagal withdrawal — the intervention directly targets the measured variable |
| **Cyclic sighing (double inhale, extended exhale), 5 min/day** | Balban et al. 2023, *Cell Reports Medicine* (NCT05304000), RCT vs box breathing, cyclic hyperventilation, and mindfulness | Greater mood improvement and greater reduction in respiratory rate than mindfulness meditation; exhale-focused arm was the strongest | **The best-evidenced brief acute intervention.** Acute arousal spikes. |
| **Box breathing (equal in / hold / out / hold), 5 min** | Balban et al. 2023 — one of three breathwork arms, all of which improved mood; cyclic sighing was strongest. A 2025 trial compared box breathing against 6/min for post-HIIT cardiovascular recovery | Mood and arousal improvement; familiar and easy to teach | ✅ Solid second-line. Its value is **familiarity and portability**, not superiority. |
| **Silent breath-observation (focused-attention meditation), 10 min** | A single 10-min focused-attention session reduced pre-exercise state anxiety vs both random thinking and controlled breathing; 10-min guided mindful breathing improved attention markers vs control in meditation-naïve participants; dose-response between 10 and 20 min is minimal | State anxiety ↓, state mindfulness ↑, attention markers ↑ | ✅ **The option that works anywhere** — no pacing, no visible movement, no audible breathing. |
| **Passive / gentle held stretching, 5–10 min** | A single passive-stretch session raised RMSSD **+15 %** and HF **+37 %**, peaking ~30 min after; responders and non-responders were distinguishable | Parasympathetic shift, delayed rather than immediate | ⚠️ **Only passive.** See the trap below. |
| **Active static stretching** | Increases sympathetic modulation ~20 % and **decreases** parasympathetic ~30 %; elevates HR and BP with vagal withdrawal | The opposite of a downshift | ❌ **Never offer for a downshift nudge.** |
| **10-minute outdoor / physical activity break** | MDPI 2024 healthcare-worker RCT; Frontiers Psychol 2018 nature-walk field studies; park-walk lunch-break RCTs | Improved attention and executive function; restoration from job stress; mood and vitality | Sedentary and time-on-task triggers |
| **Specific I:E ratio (4:7, 3:7 …)** | Mixed. A 2024 *Applied Psychophysiology and Biofeedback* study found a 1:2 ratio did **not** affect time-domain, frequency-domain or non-linear HRV, confirmed in replication. A 2021 review found 3 studies with no ratio effect, 1 favouring equal, 4 favouring longer exhale. | Perceived anxiety does fall with longer exhales; the HRV effect is unreliable | ❌ **Not a dose ladder.** See below. |

**The stretching trap.** "A little stretching" splits into two interventions with *opposite* autonomic signs. Passive stretching — a held position, body relaxed, no active muscular effort — raises vagal modulation. Active static stretching — holding a stretch under your own muscular effort — produces roughly 20 % more sympathetic and 30 % less parasympathetic activity. Offering "stretching" generically would, for a meaningful share of users, prescribe the opposite of what the trigger called for. The library therefore offers **gentle held stretches only**, with copy that specifies relaxed and supported, and the app must not describe it as a "stretch routine".

**An honesty note on slow breathing.** A 400-participant RCT (NCT05676658) comparing coherent breathing at ~5.5/min against a 12/min attention-placebo for 4 weeks found **no significant between-group difference in subjective stress** post-intervention. The acute physiological effects of paced breathing are well established; sustained subjective benefit at trial scale is less certain than the popular literature implies. This is a reason to (a) keep nudges rare, (b) frame copy around what the user will feel in the next few minutes rather than promising lasting change, and (c) let the impact pipeline tell each user what actually works for *them* (§5.1).

**Consequence for the preset mapping.** Revision 1 assigned a different I:E ratio per trigger as a severity ladder — 4:6 → 4:7 → 3:7 as arousal rose. That ladder is not supported: the ratio evidence is genuinely mixed and the best-powered recent test found no HRV effect at 1:2. **Rate is the validated lever, not ratio.** All resonance-breathing nudges therefore use ~6/min at the app default 4:6, and the spec makes no claim of ratio-graded dosing.

**Consequence for the practice catalog.** Cyclic sighing is the single best-evidenced 5-minute intervention for acute mood and arousal, and **the app cannot deliver it.** `ActivityType.breathwork` lists it nowhere; the pacer only does symmetric rate/ratio cycles (`ResonateView.swift:11-16`), and a double-inhale-then-long-exhale pattern is not expressible in it. Adding a cyclic-sighing pacer mode is a prerequisite for D4 — see §10.

### 3.5 What grounds the focus window

Thayer & Lane's neurovisceral integration model, and the systematic-review literature built on it, link **vagally-mediated HRV** to prefrontal function: higher resting vmHRV correlates with better executive-function and inhibitory performance, via cortico-subcortical circuits shared between self-regulation and cardiac autonomic control.

This is the right foundation for F1 — and it says the focus window should be built on **RMSSD/RSA**, not on PIP. Revision 1 had it inverted, with PIP as the primary criterion.

**Not used:** the 90-minute ultradian / basic-rest-activity-cycle framing. The waking manifestation is inconsistent, easily masked by caffeine, stress and social context, and not all studies support a clean cognitive rhythm. The spec does not claim a cycle and does not try to predict the next window.

### 3.6 What changed from revision 1

| Rev 1 | Rev 2 | Reason |
|---|---|---|
| D1 `inner_noise_rising` (PIP, 30 min) | **withdrawn** | PIP is non-autonomic, trait-scale (§3.2) |
| D2 `settling_fading` (DC, 30 min) | **withdrawn** | DC is a 24-h marker (§3.3) |
| D3 `arousal_climbing` | **D1**, unchanged in substance | Best-grounded trigger in rev 1 |
| — | **D2** `sustained_load` (new) | Time-on-task HRV/fatigue literature |
| D4 `stuck_still` | **D3**, strengthened | Activity-break RCTs |
| D5 `acute_spike` | **D4**, intervention changed | Cyclic sighing > resonance for acute arousal |
| F1 on PIP primary | **F1 on vmHRV primary** | Neurovisceral integration (§3.5) |
| I:E ratio severity ladder | **removed** | Ratio evidence is mixed (§3.4) |
| One prescribed action per trigger | **Menu: primary + alternates** (§5.1) | Context determines whether an intervention is usable at all; and per-user response varies enough that group-level evidence should only set the *starting* order |

Four downshift triggers, not five. Revision 1 targeted five because five slots were asked for; two of them did not survive the evidence test, and inventing a replacement to keep the count would be the same error.

---

## 4. Sampling substrate

### 4.1 Two windows

- **Slow — 30 min**, 5 × 6-min buckets. Bucket centres 24 min apart, clearing the 20-minute buffer span from §2.4. Used for `rmssd`/`balance`, `rsa`, `dfa1`, `coherence`, `breath_bpm`, `motion`.
- **Fast — 10 min**, 5 × 2-min buckets. Used only by D4, on HR, RSA and motion.

### 4.2 `NudgeSampleBuffer`

- **Where:** appended *before* the `if inForeground` branch at `AppEnvironment.swift:367`, by hoisting the existing `MetricsHistoryPoint(from: tick)` construction (`:369`) out of the branch.
- **Gate at append:** `MetricsQualityFilter.isValid` (`Models/MetricsHistoryPoint.swift:8-21`). A rejected tick never enters and counts as a gap.
- **Retention:** 45 min. **Cap:** 1600 entries, trimmed in batches of 200, mirroring `trimBatch` at `:113`. ≈400 KB.
- **Minimum points:** `required(W) = max(6, Int(0.6 × W × 60 / medianΔt))` — derived from observed cadence, never hardcoded.
- **Not persisted.** A cold launch means a 30-minute warm-up; rehydrating from SwiftData would let a nudge fire on pre-crash data.
- **Gap rule:** any Δt > 5 min resets sustain counters and the stillness accumulator and forces a refill.

### 4.3 Personal units — `dzSlow`, not live z

The baseline is built from rested morning anchors under strict gates (`Metrics/AnchorDetector.swift:84-90`), so live daytime values are systematically worse *by construction* and an absolute live z is biased. The primitive is the change across the slow window in the person's own SD units:

```
dzSlow(m) = (slow30[m].buckets[4] − slow30[m].buckets[0]) / baselineSD(m)
```

The anchor-vs-live offset cancels. Each trigger pairs one `dzSlow` condition (personal, offset-free) with one absolute RefLine condition (level-anchored).

This also aligns with the baseline literature the code already cites — `AnchorBaseline.swift:18-21` invokes Plews et al.: single-day-vs-single-day comparison is noise, and the validated approach is a rolling personal baseline with a smallest-worthwhile-change band.

### 4.4 Derived series

`balance` and `motion` are not in `keyPaths` and must not be added — `LiveStateTrendCompute.swift:43-44` documents that list as the server payload contract. Expose the private `trend(for:dayMean:buckets:)` (`:104`) instead. `MetricTrend.dayMean` must never appear in a rule: it averages the whole array passed in, which here is 45 minutes, not a day.

---

## 5. Trigger taxonomy — four downshift

Orthogonal axes: D1 → vagally-mediated HRV, D2 → DFA α1 + time-on-task, D3 → motion + duration, D4 → HR (fast path).

Evaluation runs at most once per 55 s.

### 5.1 The intervention library

A nudge does not prescribe one action. It offers a **primary** — the best-evidenced option for that state — and a short list of alternates the user can pick instead. The reason is practical: the best intervention for a state is worthless if the user is in a meeting, at a desk in an open-plan office, or unable to leave the building. A menu that respects context gets used; a prescription that ignores it gets dismissed.

Every item below is evidence-backed (§3.4). The columns that matter operationally are **where** it can be done and **how long** it takes.

| id | Option | Time | Where it works | Needs |
|---|---|---|---|---|
| `resonance` | Slow paced breathing, ~6/min | 5 min | Anywhere you can breathe slowly | ✅ exists (`ResonateView`) |
| `sighing` | Cyclic sighing — double inhale, long exhale | 5 min | Private-ish; the exhale is audible | ⚠️ pacer holds |
| `box` | Box breathing — equal in / hold / out / hold | 5 min | Anywhere; silent and familiar | ⚠️ pacer holds |
| `observe` | Silent breath observation | 10 min | **Anywhere, including a meeting** | 🔨 timer only |
| `stretch` | Gentle held stretches, relaxed and supported | 5–10 min | Somewhere you can stand or sit freely | 🔨 timer + guidance |
| `walk` | Walk, outdoors and in daylight if possible | 10 min | Requires leaving the desk | ✅ exists (`ActivityLogging.begin`) |

Build cost is deliberately included: `observe` and `stretch` need only a timer and copy — no pacer work — so the library can ship with **four** of six options before any pacer changes land, and the two breathing variants follow.

**Ordering rules.**

1. The primary is fixed per trigger by evidence (§5.3).
2. Alternates are ordered by *decreasing* evidence strength for that state, except that at least one **silent, stay-at-desk** option (`observe` or `box`) always appears — so there is never a nudge the user cannot act on where they are.
3. `stretch` is never offered as a primary. Its vagal effect peaks ~30 min after the session, which makes it a poor fit for a nudge answering a state *right now*, though a good fit for someone who wants to move without leaving the room.
4. `walk` is dropped from the list when the trigger already requires stillness and the user has signalled they cannot leave — see the Settings preference below.

**Personalisation, and why it belongs here.** Every option a user takes from a nudge becomes an `ActivityLog` with before/during/after windows and an impact score (`ActivityImpact.score`, currently an unweighted mean across the nine display metrics). After enough repetitions the app can order each trigger's menu by *that user's own measured response* rather than by the group-level literature — which matters more than usual here, since the passive-stretch trial explicitly separated responders from non-responders, and the 400-person coherent-breathing RCT found no group-level subjective effect at all. The literature picks the starting order; the user's own data should pick the final one.

This is a Phase 3 feature, not Phase 2 — it needs a meaningful sample per option per user. The spec's requirement for Phase 2 is only that the data model make it possible: record **which** option was offered, which was chosen, and which was dismissed, so the ranking can be computed later.

**Settings.** The `NUDGES` section (§9) gains a per-option toggle, so a user who dislikes meditation or cannot take walks during the day removes those from every menu permanently. Defaults: all on.

### 5.2 Preconditions common to all four

```
slow30.motion.max < 20.0 mg                     // AnchorThresholds.stillnessSD
now − lastActiveAt ≥ 45 min                     // post-exertion lockout
fast10.hr.mean < baseline.restingHR.mean + 35   // exertion ceiling
NOT energyNotStress                             // §7 layer 3
```

*(D3 requires stillness by definition, so layers 1–2 are automatic there.)*

### 5.3 The triggers

#### D1 · `downshift.vagal_withdrawal` — Arousal up, regulation down

The core stress trigger, and the best-grounded one: the measured variable and the intervention's mechanism are the same thing.

```
slow30.balance.direction == "rising"
slow30.balance.shape     == "steady-rise"
slow30.balance.end       ≥ 65.0    // "sympathetic" RefLine, :1231 ≡ RMSSD ≤ 21.5 ms
dzSlow(lnRMSSD)          ≤ −0.8
slow30.breath_bpm.mean   ≥ 9.0     // AutonomicCompute.swift:59 `paced` guard
sustain: 3 evaluations
```

Do **not** additionally test `rmssd < 20` — by §2.1 that is the same test twice. The breathing-rate clause prevents firing while the user is already doing breathwork.

**Primary:** `resonance` — ~6 br/min, app-default 4:6, 5 min. Breathing at ≈0.1 Hz maximises RSA amplitude through baroreflex resonance, acting directly on the vagally-mediated variable the trigger detected. No ratio claim is made (§3.4).
**Alternates:** `box` (silent, stays at the desk) · `observe` (10 min, works in a meeting) · `stretch` (if they'd rather move than breathe).

> **You've been running hot**
> Your stress dial has been climbing for half an hour and is sitting in the revved-up zone. Five minutes of slow breathing brings it down.
> `Start 5-minute reset`  ·  `Something else`

#### D2 · `downshift.sustained_load` — Long stretch under load

New in revision 2. Grounded in the time-on-task literature: HRV declines with prolonged cognitive task performance, and DFA α1 falls under mental workload as well as physical exertion.

```
now − loadSince ≥ 90 min
   // loadSince = start of the current continuous seated-and-connected stretch;
   // resets on any activity log, on a >5 min gap, or on BLE standby.
AND slow30.dfa1.end ≤ 0.85         // between "Drifting" 0.75 and "In Harmony" 1.0, :1198
AND dzSlow(lnRMSSD) ≤ −0.5
sustain: 3 evaluations
```

Both metric clauses are required: DFA α1 alone is dominated by the exercise-intensity literature and would be ambiguous, so pairing it with a vagal decline and a duration gate is what makes this a cognitive-load reading rather than an exertion reading. The 90-minute duration and the −0.5 are first guesses.

**Primary:** `walk` — 10 min, outdoors and in daylight if possible. Ten-minute activity breaks improved attention and executive function in an RCT; nature-walk field studies show restoration and mood gains. This is the trigger where the movement evidence is strongest, because the deficit is cognitive rather than autonomic.
**Alternates:** `stretch` (movement without leaving the room — and the ~30 min lag matters less here, since the goal is restoration over the next hour rather than an immediate downshift) · `observe` (10 min, if they cannot move at all) · `resonance`.

> **You've been at it a while**
> Ninety minutes of steady output, and your recovery signal is drifting down with it. Ten minutes away from the screen restores more than pushing through does.
> `Start a walk`  ·  `Something else`

#### D3 · `downshift.stuck_still` — Sedentary stretch

```
stillSince != nil AND now − stillSince ≥ 50 min
   // scalar Date? accumulator, NOT the buffer — 50 min exceeds the 45-min retention.
   // Resets on any tick with motion ≥ 20 mg, on a >5 min gap, or on BLE standby.
sustain: 3 evaluations
```

Revision 1 gated this on a DFA α1 *or* PIP clause. The PIP half is withdrawn (§3.2), and the DFA half now belongs to D2. What remains is the cleanest version: sedentary exposure is itself the validated intervention target, and it needs no HRV corroboration. 50 min is a first guess that clears the 90-min spacing budget naturally.

**Primary:** `walk` — 10 min, outdoors and in daylight if possible. Same evidence as D2, and here the sedentary exposure *is* the thing being corrected, so movement is the mechanism rather than a proxy.
**Alternates:** `stretch` (the closest substitute when leaving isn't possible — it at least breaks the postural stillness) · `observe` · `box`.

Note this is the one trigger where a breathing option is a genuine compromise rather than an equal alternative: breathing does nothing about sedentary exposure. The menu should still offer it — a nudge with no actionable option is worse — but the copy leads with movement.

> **You've been still for a while**
> Nearly an hour without moving. Ten minutes outside — ideally daylight — resets more than you'd expect.
> `Start a walk`  ·  `Something else`

#### D4 · `downshift.acute_spike` — Something just landed

The fast path. Every other trigger carries 15–25 minutes of latency (§2.4); without this the feature is never responsive.

```
fast10.hr.shape                 == "steady-rise"
fast10.hr.end − fast10.hr.start ≥ 12 bpm
fast10.hr.end                   ≥ baseline.restingHR.mean + 15
fast10.motion.max               <  20.0 mg     // the key discriminator
fast10.rsa.direction            == "falling"
sustain: 2 evaluations
```

HR rising 12 bpm over 10 minutes while the strap reads under 20 mg cannot be exertion. RSA at a 90 s window is the only recovery metric fast enough to corroborate inside the window. The +12 and +15 are first guesses.

**Primary:** `sighing` — cyclic sighing, 5 min. In the Balban RCT the exhale-emphasised arm produced greater mood improvement and greater respiratory-rate reduction than mindfulness meditation, and outperformed box breathing, at exactly this dose. For an acute arousal spike it is better-evidenced than resonance breathing, which is validated for training baroreflex gain rather than for acute mood.
**Alternates:** `resonance` · `box` · `observe`.

⚠️ **Blocked:** the pacer cannot express double-inhale-then-extended-exhale (§3.4). Until §10's pacer work lands, D4's primary falls back to `resonance` and the menu ships with three options instead of four.

Note the alternates here are deliberately all breathing or stillness — no `walk`, no `stretch`. Something has just spiked; the useful response is immediate and in-place, and sending someone out of the room is the wrong shape of answer.

> **Something just landed**
> Your heart rate jumped without you moving. Five minutes of sighing breaths takes the edge off before it settles in.
> `Start 5-minute reset`  ·  `Something else`

---

## 6. F1 — The focus window

Rebuilt on vagally-mediated HRV per §3.5, with PIP demoted out of the primary criteria.

**Level conditions**

```
slow30.balance.mean   ≤ 45.0            // "parasympathetic" RefLine, :1229 ≡ RMSSD ≥ 48.9 ms
   AND baseline.lnRMSSD.z(ln(mean rmssd)) ≥ 0     // at or above their own norm
slow30.rsa.mean       ≥ 30.0            // "mod" RSA RefLine, :1016
slow30.dfa1.mean      ∈ 0.90 … 1.20     // well-organised, neither drifting nor rigid
slow30.coherence.mean ≥ 0.50
```

The vmHRV pair carries the claim — that is the axis the neurovisceral-integration literature ties to executive function. DFA α1 stays as an organisation check. **PIP is no longer a level condition.**

**Stability conditions**

```
slow30.balance.shape ∈ { plateau, steady-fall }
slow30.rsa.shape     ∈ { plateau, steady-rise }
slow30.hr.volatility == "low"                      // < 2% relative SD of bucket means
```

HR is the stability test deliberately — per §2.4 the slow series are too smoothed for volatility to mean anything.

**Context conditions**

```
slow30.motion.mean     < 20.0 mg                   // seated and working, not walking
slow30.breath_bpm.mean ∈ 10.0 … 20.0               // spontaneous, not paced
every point: signalQuality ≥ 0.9 AND ecgQualityTier ≥ 1
```

The quality gate reuses the anchor gates verbatim. A "you're in a great state" claim must not be derivable from a noisy read.

**Sustain:** 10 consecutive evaluations ≈ 10 minutes. Total evidence horizon 40 minutes.

### Delivery: silent

A push notification would interrupt the exact absorbed state it is reporting. F1 never pushes. It writes a `FocusWindow` record with its interval, surfaced as a past-tense card on the Live tab at next open:

> **THIS WAS YOUR WINDOW · 11:20–12:05**
> You were calm, steady and clear for 45 minutes. Worth protecting that slot tomorrow.

The spec makes **no claim about when the next window will occur** — §3.5 explains why the ultradian framing was not used. Over weeks the accumulated records may reveal a personal pattern empirically; that is a later feature, not an assumption baked in now.

**Budget:** ≤1/day, work hours only.

**Tuning order if it never fires:** loosen coherence → then RSA 30 → 25 → then volatility. Never loosen the vmHRV pair or the quality gate; those carry the claim.

---

## 7. The exercise false-positive problem

`server/routers/insights.py:151-154`: *"a high or rising HR with GOOD recovery metrics is high ENERGY, not stress."* Four layers, before any downshift rule.

**Layer 1 — Motion floor.** Every downshift requires `slow30.motion.max < 20 mg` across the entire window, reusing `AnchorThresholds.stillnessSD` (`AnchorDetector.swift:9`).

> ⚠️ Use `MetricsHistoryPoint.motion` — SD of ACC **vector magnitude** in mg (`MotionCompute.swift:14-16`). **Never** `env.accMotion`, which is mean **per-axis** SD on a different scale with threshold 3.0 (`AppEnvironment.swift:254`). Confusing them silently breaks every motion gate.

**Layer 2 — Post-exertion lockout.** RMSSD stays suppressed for 30–60 min after exertion ends. Track `lastActiveAt` = last tick where `motion ≥ 60 mg` sustained ≥ 3 min; suppress downshift for 45 min after, and after any `.exercise / .run / .walk / .coldExposure / .sauna` activity. Both figures need calibration against a real captured walk.

**Layer 3 — Energy-not-stress rule.** Even while sedentary, veto D1 and D4 when:

```
slow30.hr.direction == "rising"
AND dzSlow(lnRMSSD) ≥ −0.3
AND dzSlow(dc)      ≥ −0.3
AND slow30.rsa.direction != "falling"
```

**Layer 4 — HR ceiling.** Suppress all downshift above `restingHR.mean + 35` regardless of motion — specifically for stationary cycling and rowing, where chest ACC is low but HR is at exertion levels and layer 1 misses entirely.

---

## 8. Precedence, hysteresis, budget

**Precedence:** `F1 > D4 > D1 > D2 > D3`. Exactly one fires per evaluation. F1 first because it is silent and cannot annoy; D4 next because it is time-critical; D3 last because it is the most delay-tolerant.

**Per-trigger FSM:** `idle → arming → fired → releasing → idle`. Sustain counters reset to 0 on any failing evaluation.

**Hysteresis** — release thresholds ~5 % back toward normal:

| Trigger | Arms | Releases |
|---|---|---|
| D1 | `balance ≥ 65`, `dz ≤ −0.8` | `balance < 62`, `dz > −0.6` |
| D2 | `dfa1 ≤ 0.85`, `dz ≤ −0.5` | `dfa1 > 0.89`, `dz > −0.35` |
| D4 | `Δhr ≥ 12` | `Δhr < 9` |
| F1 | e.g. `balance ≤ 45` | `balance > 47` — 5 % band on every bound |

**Clearing** requires all three: release true on 2 consecutive evaluations, ≥30 min since firing, and the global 90-min refractory elapsed.

**The anti-nag rule:** a trigger that never releases does **not** re-fire. If arousal stays high all afternoon, the user is told once. ≤3/day is a ceiling, not a target — expect 0–2. The same id cannot repeat within 3 h.

**Ledger** in `UserDefaults` so a background relaunch doesn't reset it. Day rollover by `Calendar.startOfDay` comparison, the pattern `LiveView.refreshForDayChange` already uses.

**Quiet hours (22:00–07:00)** suppress and **do not queue**.

**Suppressors** — any true, evaluate nothing and hold counters: quiet hours · `ble.state == .standby` · an `ActivityLog` with `isActive == true` · baseline nil · warm-up incomplete · a >5 min gap in the last 30 min · budget exhausted.

---

## 9. Cold start and copy

### Cold start

Below `AnchorBaseline.minimumAnchors = 7` (`Metrics/AnchorBaseline.swift:38,53`) the engine hard-suppresses and returns a *reason*, not a bool, so the UI can explain itself. A second cold start applies: the buffer is not persisted, so every cold launch costs a 30-minute warm-up.

Surfaced two ways: a line under the existing `DayPotentialStrip` "LEARNING YOUR RANGE" state (`:74-75`) reading *"Nudges start once I've learned your range — n of 7 mornings"* with the 7 read from the constant; and a `NUDGES` section in `SettingsView` showing state / today's count / next eligible time / current suppression reason.

### Copy

Plain language only, per the ban list at `insights.py:88-92`. **Note:** with PIP demoted, the phrase "Inner noise" no longer appears in any nudge — which sidesteps the framing problem in §3.2 rather than propagating it.

`Models/PolyvagalState.swift:142-239` is **not reusable** — "activate your parasympathetic nervous system", "RSA Amplification" violate the plain-language standard, and `infer` (`:32-39`) is a 3-branch classifier with a catch-all `return .regulated`. `UI/Live/RecommendedActionCard.swift` **is** worth reusing as a view shell: header, duration pill, "Why it works?", primary CTA, and a "Not now" label at `:99` behind `onAction` (`:5`, `:81`) that is currently a no-op and would finally have a purpose feeding dismissals into the ledger.

Each nudge's "Why it works?" should carry a one-line, plain-language version of its §3.4 evidence — the mechanism, not a citation.

---

## 10. Prerequisites and rollout

### Prerequisite code changes

| File | Change |
|---|---|
| `Metrics/LiveStateTrendCompute.swift:67` | `minimumPoints` as a parameter — **blocking** (§2.2) |
| `Metrics/LiveStateTrendCompute.swift:104` | expose `trend(...)` for derived series; do **not** touch `keyPaths` |
| `App/AppEnvironment.swift:367-369` | hoist `MetricsHistoryPoint(from:)` above the foreground branch; append to `NudgeSampleBuffer` |
| `UI/Resonate/ResonateView.swift:6-7` + `ResonanceSessionView.swift` | add `init(bpm:presetIndex:)` — currently impossible (§2.5) |
| **new:** `UI/Practice/BreathObserveView.swift` | `observe` — a 10-min silent timer with minimal UI. No pacer. Ships in Phase 2 |
| **new:** `UI/Practice/StretchTimerView.swift` | `stretch` — a 5–10 min timer with copy for **gentle held, supported** stretches. Must not read as an active stretch routine (§3.4) |
| `UI/Resonate/PacerCircleView.swift` | **new:** hold phases, enabling both `box` (in/hold/out/hold) and `sighing` (double inhale → extended exhale). Prerequisite for D4's primary (§3.4). The pacer currently models only `cycle = 60/bpm` split by an I:E ratio, with no breath-hold concept |
| `Models/ActivityLog.swift` | record which option was **offered**, **chosen** and **dismissed** per nudge, so per-user ranking is computable in Phase 3 (§5.1) |
| `App/AppEnvironment.swift:46` | `pendingNudgeAction` alongside the existing `pendingTabRequest` |
| `Info.plist` + permission flow | `UserNotifications` — Phase 2 only |

### Rollout

**Phase 1 — shadow mode.** Ship the engine with a `NudgeShadowLog` recording every evaluation's candidate set, selection and suppression reason. No notifications, no UI, no permission prompt. Wear it ~2 weeks. Read from the log: how often each trigger *would* have fired, at what hours, how often the exercise veto saved us, and whether F1 ever fires at all.

**Phase 2 — tune, then enable.** Adjust thresholds, add the permission flow and delivery. Target rates: ~0.8–1.5 downshift/day, 1–2 focus windows/week.

### Testability

Pure functions over synthetic `[MetricsHistoryPoint]`, following `WythinTests/StreakComputeTests.swift`: `NudgeSignals.derive`, `NudgeSuppression.evaluate` (returns reason), `NudgeTriggers.evaluate`, `NudgePrecedence.select`, `NudgeStateMachine.advance`, `NudgeBudget.allows`, `ExerciseVeto.isLikelyExertion`, `NudgeCopy.render`.

Highest-value tests: one near-miss array per clause per trigger; a synthetic run (motion 200 mg, HR +50, RMSSD 12) and a synthetic stationary bike (motion 15 mg, HR +40, RMSSD 14) both asserting no downshift fires; a flapping input that must never fire; a banned-term assertion over every rendered string.

---

## 11. Open questions

1. **The "Inner Noise" framing beyond SP6.** §3.2 shows PIP is validated as a non-autonomic, age-and-disease marker, not a real-time focus proxy — yet it is presented as one in the live-state prompt (`insights.py:132-138`, `:235-236`), the impact grid, and the Live tile. Do we reposition it app-wide as a slow burden indicator, or leave the existing surfaces and only hold SP6 to the stricter standard?
2. **Do the pacer hold-phases get built for SP6?** They unlock both `sighing` (D4's evidence-backed primary) and `box` (the most familiar option to most users). Without them the library ships with four of six options — still usable, but D4 falls back to a less well-evidenced primary.
3. **How many alternates before the menu becomes friction?** The spec offers three. A nudge is an interruption; a menu makes the interruption longer. An alternative shape is primary + a single "Something else" that cycles, rather than a list. Worth testing in Phase 2 rather than deciding now.
4. **Should `stretch` copy include actual stretch suggestions, or stay abstract?** Naming specific stretches risks drifting into active stretching, which is autonomically the wrong direction (§3.4). Abstract copy ("something gentle you can hold, relaxed") is safer but vaguer.
5. **Work-hours definition for F1** — hardcode 09:00–18:00 Mon–Fri, ask at onboarding, or infer from when the strap is habitually worn?
6. **Day-1 users.** D3 needs no baseline at all — it is motion and duration only. Allow it before 7 anchors so new users get something, or hard-suppress everything for consistency?
7. **Should the balance dial become personal?** Passing `exp(baseline.lnRMSSD.mean)` as `baselineRmssd` would make the user's own baseline read exactly 50 (`AutonomicCompute.swift:79-80`) — a better nudge input, but then the nudge's dial and the chart's dial disagree.
8. **Shadow-mode exit criteria.** Two weeks is a guess. What fire rate counts as correct?

---

## 12. References

**Metrics**

- Costa MD, Davis RB, Goldberger AL. Heart Rate Fragmentation: A New Approach to the Analysis of Cardiac Interbeat Interval Dynamics. *Front Physiol* 2017;8:255. — https://pmc.ncbi.nlm.nih.gov/articles/PMC5422439/
- Lensen IS, Monfredi OJ, Andris RT, Lake DE, Moorman JR. Heart rate fragmentation gives novel insights into non-autonomic mechanisms governing beat-to-beat control of the heart's rhythm. 2020. — https://pmc.ncbi.nlm.nih.gov/articles/PMC7457638/
- Heart Rate Fragmentation as a Novel Biomarker of Adverse Cardiovascular Events: The Multi-Ethnic Study of Atherosclerosis. — https://pmc.ncbi.nlm.nih.gov/articles/PMC6129761/
- Heart Rate Fragmentation: A Novel Analytic Approach to Detect Allostatic Load Among Healthy Adults. *Appl Psychophysiol Biofeedback* 2025. — https://link.springer.com/article/10.1007/s10484-025-09721-1
- Bauer A, et al. Deceleration capacity of heart rate as a predictor of mortality after myocardial infarction: cohort study. *Lancet* 2006. — https://www.thelancet.com/journals/lancet/article/PIIS0140-6736(06)68735-7/abstract
- Change in heart rate variability with increasing time-on-task as a marker for mental fatigue: A systematic review. 2023. — https://www.sciencedirect.com/science/article/pii/S0301051123002478
- Mental Workload Alters Heart Rate Variability, Lowering Non-linear Dynamics. — https://pmc.ncbi.nlm.nih.gov/articles/PMC6528181/

**Interventions**

- Balban MY, et al. Brief structured respiration practices enhance mood and reduce physiological arousal. *Cell Reports Medicine* 2023 (NCT05304000). — https://www.cell.com/cell-reports-medecine/fulltext/S2666-3791(22)00474-8
- Laborde S, et al. Psychophysiological effects of slow-paced breathing at six cycles per minute with or without heart rate variability biofeedback. *Psychophysiology* 2022. — https://onlinelibrary.wiley.com/doi/10.1111/psyp.13952
- Heart rate variability (HRV): From brain death to resonance breathing at 6 breaths per minute. — https://www.sciencedirect.com/science/article/abs/pii/S1388245719313021
- Do Longer Exhalations Increase HRV During Slow-Paced Breathing? *Appl Psychophysiol Biofeedback* 2024. — https://pmc.ncbi.nlm.nih.gov/articles/PMC11310264/
- Slow-Paced Breathing: Influence of Inhalation/Exhalation Ratio and of Respiratory Pauses on Cardiac Vagal Activity. *Sustainability* 2021. — https://www.mdpi.com/2071-1050/13/14/7775
- Ten-Minute Physical Activity Breaks Improve Attention and Executive Functions in Healthcare Workers. 2024. — https://www.mdpi.com/2411-5142/9/2/102
- Can Nature Walks With Psychological Tasks Improve Mood, Self-Reported Restoration, and Sustained Attention? *Front Psychol* 2018. — https://pmc.ncbi.nlm.nih.gov/articles/PMC6218585/
- Effects of park walks and relaxation exercises during lunch breaks on recovery from job stress: Two randomized controlled trials. — https://www.sciencedirect.com/science/article/abs/pii/S0272494417300294
- Increases in cardiac vagal modulation following muscle mechanoreflex activation via passive calf stretch. — https://pmc.ncbi.nlm.nih.gov/articles/PMC12756858/
- Acute effects of different static stretching exercises orders on cardiovascular and autonomic responses. *Sci Rep* 2019. — https://www.nature.com/articles/s41598-019-52055-2
- Effects of Acute Stretching Exercise and Training on Heart Rate Variability: A Review. *J Strength Cond Res*. — https://www.ovid.com/jnls/nsca-jscr/abstract/10.1519/jsc.0000000000003084
- Box breathing or six breaths per minute: Which strategy improves athletes' post-HIIT cardiovascular recovery? 2025. — https://pmc.ncbi.nlm.nih.gov/articles/PMC12622787/
- Effect of coherent breathing on mental health and wellbeing: a randomised placebo-controlled trial (NCT05676658, n=400). — https://pmc.ncbi.nlm.nih.gov/articles/PMC10719279/
- The Effect of Slow-Paced Breathing on Cardiovascular and Emotion Functions: A Meta-Analysis and Systematic Review. *Mindfulness* 2023. — https://link.springer.com/article/10.1007/s12671-023-02294-2
- Focused Attention Meditation as a Pre-Exercise Strategy for Reducing Anxiety. — https://pmc.ncbi.nlm.nih.gov/articles/PMC12846251/
- Brief Mindfulness Meditation Improves Attention in Novices: Evidence From ERPs. *Front Hum Neurosci* 2018. — https://www.frontiersin.org/journals/human-neuroscience/articles/10.3389/fnhum.2018.00315/full
- The effect of ten versus twenty minutes of mindfulness meditation on state mindfulness and affect. *Sci Rep* 2023. — https://www.nature.com/articles/s41598-023-46578-y

**Focus / cognition**

- Thayer JF, Hansen AL, et al. Heart Rate Variability, Prefrontal Neural Function, and Cognitive Performance: The Neurovisceral Integration Perspective. — https://www.semanticscholar.org/paper/f2382c15763fb5c2b8cb22a1de7beaf64dd96c3b
- Heart Rate Variability and Cognitive Function: A Systematic Review. *Front Neurosci* 2019. — https://www.frontiersin.org/journals/neuroscience/articles/10.3389/fnins.2019.00710/full
- The intricate brain–heart connection: The relationship between heart rate variability and cognitive functioning. *Neuroscience* 2024. — https://www.ibroneuroscience.org/article/S0306-4522(24)00705-X/fulltext
