# The Sleep Metric Hierarchy — categories, metrics, evidence, status

Companion to `2026-08-18-sleep-tracking.md`, which ranked the evidence. This one
answers a narrower question: **what should the app actually show, at what level,
and which of it only a chest ECG strap can see.**

Every citation below is carried over from the August report, where the sources
are linked. Claims **not** in that report are marked ⚠️ — they are domain
knowledge that has not been checked against a source in this repo, and should be
before anything is built on them.

---

## The shape of the problem

The five sections shipping today are not on one level, and that is why the card
reads unevenly. Three different kinds of thing are being scored side by side:

- **outcomes** — things with direct evidence linking them to how long and how
  well people live (timing, duration)
- **mechanism** — physiology that explains the night (autonomic recovery)
- **description** — restatements of whether you were asleep (continuity,
  breathing steadiness)

And one pillar of clinical sleep medicine is missing entirely: **the airway**.

---

## Category level

Five categories. The first four are mutually exclusive; the fifth is absent from
the product today and is the largest single gap.

| # | Category | The question it answers | Scored today | Should be scored |
|---|---|---|---|---|
| **A** | **Timing** | When did you sleep, and how consistently? | ✅ 25% | ✅ |
| **B** | **Duration** | How much, against *your* need? | ✅ 25% | ✅ |
| **C** | **Continuity** | How unbroken was it? | ✅ 15% | ✅ — raised, once arousals exist |
| **D** | **Airway** | Did breathing obstruct? | ❌ (15% goes to breath *steadiness*) | ✅ — when built |
| **E** | **Autonomic** | How did the nervous system respond? | ✅ 20% | ✅ |

Not a category: **stages**. Independent validation puts consumer 4-class
agreement at κ 0.21–0.53 with wake specificity 29–52%; the human inter-rater
ceiling is κ 0.76 and N1 is 0.24. Show the hypnogram, never score it. The
current score already excludes it, correctly.

---

## Metric level

### A. Timing

| Metric | Status | Evidence |
|---|---|---|
| **Bedtime consistency** (circular SD of onset) | ✅ built (v16) | Windred 2024, n=60,977: most- vs least-regular quintile all-cause **HR 0.70**, cardiometabolic **0.62**. Head-to-head it beat duration, and adding duration to a regularity model added nothing — **LRT χ²(4)=5.94, p=0.20**. Chaput 2024: T2D **HR 1.38**, persisting in people sleeping ≥7 h. |
| **Wake-time consistency** | ❌ | Same literature. ⚠️ Wake time is generally the stronger circadian anchor than bedtime, because light exposure on waking sets phase — worth measuring separately rather than assuming onset carries it. |
| Midpoint drift / social jetlag | ❌ | ⚠️ Standard construct; not covered in the August report. |

**Why it leads:** cheapest thing in the report to compute — needs only onset and
wake times, no ECG, no staging — and the strongest outcome evidence. Caveat
carried from the report: one cohort, mean age 62.8, partly a shift-work proxy.

**Do not use SRI.** The Sleep Regularity Index compares every minute against the
same minute 24 h earlier, so a night the strap was not worn reads as a night
spent awake. On a device worn for a few nights at a time it scores intermittent
wear, not the sleeper. Replaced 2026-09-07.

### B. Duration

| Metric | Status | Evidence |
|---|---|---|
| **Total sleep time** | ✅ built | Van Dongen 2003: 14 days at 6 h TIB ≈ one night of total deprivation; deficits **do not plateau**. Lim & Dinges 2010: lapses **g = −0.76**, reasoning spared. |
| **Personal sleep need** | ❌ **constant today** | Van Dongen 2004: between-subject SD for critical wake duration **3.58 h**; implied need **8.16 ± 0.73 h**; trait-stable and *unpredicted by baseline functioning*. A quarter of the score is currently measured against `defaultNeedSec`. |
| Sleep efficiency (TST/TIB) | ⚠️ shown, not scored | ⚠️ <85% is the conventional clinical threshold; not sourced in the August report. |

**The finding that should shape the voice:** Van Dongen's dissociation —
subjective sleepiness *saturated* while objective performance kept degrading, and
the 6 h and 4 h arms were statistically indistinguishable on self-rated
sleepiness (F=0.10, p=0.75) while their measured performance diverged. People
cannot feel how impaired they are. That is the honest case for measuring at all,
and it is stronger than "optimise your deep sleep."

### C. Continuity

| Metric | Status | Evidence |
|---|---|---|
| **Arousal index** (events/h) | ❌ **structurally invisible** | ⚠️ A cortical arousal is a ~3 s EEG shift with an autonomic signature — abrupt HR acceleration of roughly 5–10 bpm over 10–15 s, then deceleration. Current smoothing absorbs everything shorter than `minWakeRunSec` (60 s) / `minStageRunSec` (180 s), and `briefArousalSec` (120 s) resumes sleep below two minutes. **A night with 30 arousals can honestly report 2 wake bouts.** |
| WASO | ✅ built | Standard construct. |
| Number of awakenings | ✅ built | |
| **Longest unbroken stretch** | ✅ built | Deserves more prominence than the bout count: one 4 h block is not eight 30 min blocks. |
| **Return-to-sleep latency** | ❌ | ⚠️ Defines sleep-maintenance insomnia, and is exactly what someone who wakes and meditates wants to know. Also the natural outcome measure for an in-app intervention. |
| Position of awakenings in the night | ❌ | ⚠️ Slow-wave sleep is front-loaded and REM back-loaded, so an arousal in cycle 1 costs SWS and the same arousal at 05:00 costs REM. Counted identically today. |

**Honest note on the evidence.** Prather 2015 found actigraphic fragmentation
**null (p=0.755)** for infection while duration survived in the same study — the
one direct null in the August report. But that is one outcome in one study, and
forced-arousal experiments that fragment sleep at constant total duration do
degrade daytime function. ⚠️ The construct is well supported; it was the
*measurement* that was weak, and conflating the two under-rates the category.

**Why ECG suits it.** Wake-vs-sleep classification from motion is the weakest
thing wearables do (29–52% specificity). Arousal detection from beat timing is a
different and better-posed problem, and it is the same pipeline as category D —
respiratory events terminate in arousals.

### D. Airway — the missing pillar

| Metric | Status | Evidence |
|---|---|---|
| **AHI** (apnea–hypopnea index) | ❌ | Schipper 2026, n=413, hold-out 207, chest accelerometer alone: **AHI ICC 0.90 (0.86–0.92)**, bias −0.07 events/h, 4-class severity **κ 0.76**. Limits of agreement sit inside the range CPAP machines report for their own AHI. |
| **Respiratory effort waveform** | ❌ (channel exists, unused for this) | Schipper 2023, n=146, 610 h: median correlation with a RIP belt **r ≈ 0.94–0.95**; breath detection **sensitivity 98.4%, PPV 98.2%**. Respiration is a gravity-vector *tilt* signal — no privileged device axis. |
| **Obstructive vs central** | ❌ | Effort amplitude is the axis: median **0.60 (central apnea) < 0.83 < 1.93 < 3.23 < 6.42 (obstructive apnea)** against esophageal pressure — a monotonic ~10× spread. Ceiling: RIP vs esophageal reaches only κ 0.87; chest+abdomen CNN F1 central 87% / obstructive 51%. |
| **Supine share** | ⚠️ position built, link not | SHHS, n=1,870 with AHI ≥5: **62% of OSA is positional**, median supine:non-supine AHI ratio **4.8×** (**10.1×** supine-isolated). Of patients who *denied* sleeping supine only **56%** were right. **15% of lab-diagnosed positional OSA patients never sleep supine at home** — the question a lab structurally cannot answer and a multi-night home strap can. |
| Respiratory rate & variability | ✅ steadiness built | Miller 2020, 30 nights: within-person nightly **CV 3.28%** vs RHR 8.60% and RMSSD **27.2%** — the most stable overnight metric by a factor of ~8. SHHS: nocturnal RR median *and* within-night variability independently predicted mortality. |

**Never build an alert on RR.** The one prospective real-world tested-alert
study: 665 alerts, 512 panels, 63 infections — **PPV 4–10%**, ~7 alerts per
person-year, 90–96% wrong. Ship it as a retrospective explainer beside the
alcohol the user logged.

**What today's "Breathing" section actually is.** `SleepBreathing.steadyFraction`
— the share of the night whose breath *rate* held close to its own rhythm. Its
own documentation calls the same signal "the single best wake/sleep
discriminator," and `SleepBreathing.unsettled` feeds the wake classifier. So it
is largely a second measurement of *were you asleep*, scored as an independent
axis, at 15%. On a real night it read **100 while Continuity read 3** across the
same 11 h 14 m, 2 h 27 m of which was scored awake.

### E. Autonomic

| Metric | Status | Evidence |
|---|---|---|
| **Deceleration capacity** | ✅ scored (v17) | HypnoLaus, n=1,784, 4.1 y: **HR 0.63 per SD (0.47–0.84)** after FDR. Bauer 2006 post-MI **AUC 0.80** vs LVEF 0.67 and SDNN 0.69. Tertiles **>4.5 / 2.6–4.5 / ≤2.5 ms**; 13-year mortality **16.7% / 23.5% / 49.1%**. |
| **Heart-rate fragmentation** (PIP/IALS) | ⚠️ computed, **not scored** | HypnoLaus **HR 1.41 per SD**. Costa 2017, nocturnal, for CAD: **PIP AUC 0.806, IALS 0.804** vs RMSSD 0.653, SampEn 0.591, **DFA α1 0.521 — chance**. MESA: CV events HR 1.43, CV death 1.65, incident AF +31%, MACE **+60% in people with zero coronary calcium**. |
| HR nadir depth and timing | ✅ scored | ⚠️ Nocturnal HR dipping is the analogue of blood-pressure dipping; a late nadir is the signature evening load leaves. Not sourced in the August report. |
| RMSSD in quiet sleep | ✅ scored, small share | Deliberately the junior partner: **every** time- and frequency-domain HRV parameter was non-significant in HypnoLaus after FDR. Nightly CV 27.2% makes a single night weak evidence. |
| DFA α2 | ❌ (α1 only) | α1 is a good stage marker and **AUC 0.52** — chance — for disease. The August report says add α2. |

**Two cautions.** Overnight DC and PIP **do not track OSA severity** (n=157) —
they are cardiac-risk metrics, not apnea metrics. And a 2026 study found PIP
correlates with symbolic 2UV at **r = 0.74** and shifts with breathing rate: if
you report fragmentation, control for respiration, which the H10 measures two
ways.

---

## What only this device can see

The reason to run a chest ECG strap rather than a wrist tracker, in one table
(from the August report's capability matrix):

| Capability | H10 | Wrist PPG |
|---|---|---|
| Beat-to-beat RR at ECG quality | ✅ LoA ±1.5 ms | ⚠️ inflates RMSSD 40% |
| Nonlinear IBI features (fragmentation, entropy) | ✅ | ❌ **r 0.07–0.31** |
| Respiratory effort waveform | ✅ **r 0.94** | ❌ |
| Obstructive vs central | ✅ directionally | ❌ |
| Body position | ✅ ~0.76 balanced acc. | ❌ **non-injective** — the forearm has 3 joints and ~300° of freedom relative to the trunk; there is no published 4-class wrist position accuracy anywhere |
| ODI / hypoxic burden | ❌ | ✅ |
| Circadian phase (temperature) | ❌ | ✅ |
| Nightly compliance | ❌ worst | ✅ best |

**Three of the four ECG-unique wins — fragmentation, effort, arousals — are not
built.** Position is built but not linked to anything.

---

## Recommended structure

**Scored, four equal quarters** until the airway pillar exists:

```
Timing      25%   bedtime consistency
Duration    25%   against personal need   ← need is a constant today
Continuity  25%   arousal index + WASO + longest stretch
Autonomic   25%   DC + fragmentation + nadir (+ RMSSD, junior)
```

Equal quarters is a deliberate admission: the true weights are not known, and
four numbers a reader can check beats five that imply a precision nobody has.
When AHI ships, it takes a fifth share and the others fall to 20%.

**Shown, never scored:** hypnogram, supine share, respiratory rate vs baseline,
sleep efficiency, position bands.

**Moved:** breath steadiness stops being an axis and becomes an input to
continuity, which is what it measures.

### Build order

1. **Personal sleep need.** A quarter of the score is measured against a
   constant while need varies ±0.7 h. Cheapest correction with the largest
   effect on score validity.
2. **Arousal index + return-to-sleep latency.** Makes continuity a real
   measurement, and closes the loop with the practices the app already ships.
3. **Fragmentation into the autonomic section.** Already computed. Control for
   respiration rate.
4. **Airway.** Highest ceiling, and the only one that changes what the product
   *is*. Blocked on a raw-window capture mode: no raw ACC or ECG is stored
   anywhere today — the phone keeps an 82 s RAM ring buffer and the server
   stores scalars.

---

## Design constraints that outrank all of the above

From §6g of the August report, and they bind every item here:

- **No RCT anywhere tests a commercial recovery/readiness score as an
  intervention.** Under deliberate training overload, subjective metrics
  degraded while wearable nightly recovery metrics showed no consistent change.
- **Vagal HRV rises with both positive adaptation and functional overreaching.**
  A single number cannot resolve that, and no vendor discloses how they try.
- **Orthosomnia is measured at 3.0–14.0% prevalence.** Users adjust behaviour to
  improve the number rather than their health. Aggregate over ≥7 nights, avoid
  daily red/amber/green, and version-stamp every derived metric so history can be
  re-derived when the model changes.

The score already shows its arithmetic, which is the mitigation for the first
two. The version stamp exists (`algorithmVersion`, currently 17).
