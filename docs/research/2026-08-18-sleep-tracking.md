# Sleep Tracking — Design-Research Report

**Date:** 2026-08-18
**Scope:** Adding sleep measurement to Wythin. What to measure, how to model a night as an activity, what recovery and sleep-disordered-breathing signals are defensible on Polar H10 hardware, and what a chest ECG strap uniquely offers versus the wrist-PPG market.
**Inputs:** full code inventory of the current implementation (`BLE/`, `Metrics/`, `Models/ActivityLog.swift`, `AnchorDetector`, server + MCP surface) plus research reviews on sleep dose–response, OSA epidemiology and the AHI critique, PPG/accelerometer detection performance, ECG-derived staging, chest-accelerometer respiration and position, per-stage nonlinear HRV, commercial recovery scores, intervention evidence and n-of-1 causal inference, and Apple platform APIs plus FDA/EU regulatory posture. Citations inline.
**Companion:** `docs/research/2026-07-30-continuous-ecg-form-factors.md`, whose verdict — *dry electrodes are fine at rest and bad in motion; model ECG as morphology-grade capture in quiet windows* — this report follows to its conclusion. That doc already named "nocturnal HRV, ectopy burden, AF episodes, sleep-staged autonomic tone" as the payoff. This is that payoff, costed.

> **Status:** complete. All ten sections researched. Two sections (§7 intervention evidence, §8 Apple platform + regulatory) were added on 2026-08-18 after their research tracks completed; §9's permissible-language subsection was **corrected** by that research — see §8d.

---

## 0. The one-paragraph thesis

The sleep-tracking market displays **stage percentages**, which is the metric with the *weakest* outcome evidence and the *worst* measurement accuracy on consumer hardware (4-stage κ ≈ 0.21–0.53). Meanwhile the metrics that actually predict hard outcomes — sleep **regularity**, and for disordered breathing the **heart-rate response to events (ΔHR)** and **autonomic burden** rather than AHI — are either free (timing) or computable from beat-to-beat ECG plus chest-wall motion, which is exactly what Wythin already has. The strategic move is not to build a worse Oura. It is to ship what a sternum-mounted ECG + accelerometer can do that no ring can — **respiratory effort, body position, and autonomic event response, measured over many nights** — and to refuse to display the stage pie chart everyone else leads with.

**The honest caveat that shapes everything below:** the H10's staging advantage over a good PPG device is roughly *zero*. Its advantage is in what else it can measure. Build the product on the "what else," not on the hypnogram.

**And the finding that pays for the whole investigation:** the breath-hold duration this app already records is a **validated marker of a sleep-apnea endotype** — shorter holds predict *higher* loop gain (r² = 0.49; AUC 92%). We display it as a CO₂-tolerance fitness score. Read the other way round, it is a risk input we are already collecting (§7b).

---

## 1. What we have today — the honest inventory

| Asset | State | Bearing on sleep |
|---|---|---|
| **Polar H10** — single-lead ECG @130 Hz, tri-axial ACC (25/50/100/200 Hz, ±2/4/8 G, integer milli-g) on the sternum, skin-contact bit, battery (`BLE/PolarH10Profile.swift`) | Production, sole device | Beat-to-beat RR at ECG quality; chest-wall motion; body position from the gravity vector. **No PPG, no SpO₂, no temperature.** |
| **Background BLE capture** — `UIBackgroundModes: bluetooth-central`, state restoration, 30 s background tick (`AppEnvironment.swift:733-763`) | Working | An 8-hour capture path already exists. Cadence and standby policy need sleep-specific tuning (§4). |
| **`BreathingCompute.swift`** — PCA principal-axis projection of ACC XYZ, Butterworth bandpass, prominence peak detection, I:E phase | Production | This is a **respiratory-effort belt** on a chest-worn device. The single most valuable and least appreciated asset for sleep (§5). |
| **`EDRCompute.swift`** — ECG-derived respiration from RR | Production | Second, independent respiratory channel. Effort-vs-EDR divergence is the obstructive-event signature. |
| **`CoherenceCompute.swift`** — RR↔breath magnitude-squared coherence | Production | Turns out to be the **strongest published sleep-stage discriminator in the literature** (§6). Already built, currently used only awake. |
| **`AdvancedHRVCompute.swift`** — deceleration capacity (PRSA, Bauer 2006), RCMSE, HR fragmentation (PIP/IALS) | Production | Prognostically-loaded autonomic metrics; nocturnal DC and HRF are the two best-validated overnight risk markers in existence (§6). |
| **`DFACompute.swift`** — α1 over scales 4–16 | Production | Good stage marker, poor nocturnal risk marker. Needs α2 added (§6). |
| **`MotionCompute.swift`** — ACC magnitude SD, gravity high-pass, motion-state classification | Production | Actigraphy substrate + body position. |
| **`AnchorDetector`** — still-window detection, stir tolerance, gap ceiling, confidence tiers | Production, **fenced off before 04:00** | Ready-made overnight segmenter. See §4. |
| **`DailyRollup.wearSeconds`**, `HRVSample` → `metric_samples` sync | Production | Storage and sync path is type-agnostic; carries a nightly record with no new infrastructure. |
| HealthKit | **Absent entirely** — no import, no entitlement, no usage strings | Any Apple Watch / phone sleep data is a from-scratch bridge, not a borrow. |
| watchOS target | **Does not exist** | `SDKROOT = iphoneos`, two product types only. |

**What we cannot get from an H10:** SpO₂ (⇒ no ODI, no hypoxic burden), skin temperature (⇒ no circadian phase proxy, no illness/ovulation signal), airflow, EEG. Every claim below is scoped to that.

---

## 2. What sleep science says is worth measuring — ranked by evidence

| # | Construct | Evidence | Verdict |
|---|---|---|---|
| **1** | **Duration → vigilance / lapses** | [Van Dongen 2003](https://academic.oup.com/sleep/article-abstract/26/2/117/2709164): 14 days at 6 h TIB ≈ one night of total deprivation; 4 h ≈ two nights; deficits **do not plateau**. Acute TSD meta ([Lim & Dinges 2010](https://www.med.upenn.edu/uep/assets/user-content/documents/LimDinges2010MetaAnalysis.pdf)): lapses **g = −0.76 [−0.95, −0.58]**; reasoning spared (−0.13, CI crosses 0). | **Lead with it.** See the dissociation finding below. |
| **2** | **Regularity → mortality, dementia, T2D** | [Windred 2024, *SLEEP*](https://academic.oup.com/sleep/article/47/1/zsad253/7280269), n=60,977: most- vs least-regular quintile all-cause **HR 0.70 (0.59–0.83)**, cardiometabolic **0.62**. Head-to-head, AIC favoured SRI over duration (p<0.001), and **adding duration to an SRI model added nothing — LRT χ²(4)=5.94, p=0.20**. T2D **HR 1.38**, persisting in people sleeping ≥7 h ([Chaput 2024](https://europepmc.org/article/MED/39388339)). | **Cheapest high-value metric in this report.** Needs only onset and wake times — no staging, no ECG. Ship first. Caveat: one cohort, mean age 62.8, partly a shift-work/deprivation proxy. |
| **3** | Duration → energy intake | [Tasali 2022 RCT](https://europepmc.org/article/MED/35129580): +1.2 h/night ⇒ **−270 kcal/d**, doubly-labelled water. | Narrative context. |
| **4** | Duration → infection / vaccine | [Prather 2015](https://academic.oup.com/sleep/article-abstract/38/9/1353/2417971): <5 h **OR 4.50 (1.08–18.69)**; **actigraphic fragmentation null (p=0.755)** while duration survived. Vaccine ([Spiegel 2023](https://europepmc.org/article/MED/36917932)): objective short sleep **ES 0.79**, self-report **null**; men 0.93, **women 0.42 (n.s.)**. | Real but imprecise. Context, never personal prediction. |
| **5** | Short duration → mortality | [Cappuccio 2010](https://pmc.ncbi.nlm.nih.gov/articles/PMC2864873/): RR 1.12, I²=39%. MR-supported. | Fine to state. |
| **6** | Long duration → mortality | RR 1.30 but **I²=71%**; **not MR-supported**; under accelerometry the CVD relation is **L-shaped, not U-shaped**, >9 h n.s. ([*SLEEP* 2024](https://europepmc.org/article/MED/38995667)). | **Do not ship.** Long sleep marks illness; it does not cause death. |
| **7** | Sleep → athletic injury | [Milewski 2014](https://journals.lww.com/pedorthopaedics/fulltext/2014/03000/chronic_lack_of_sleep_is_associated_with_increased.1.aspx): OR 1.7 (1.0–3.0), **CI touches unity**; *school grade* was stronger in the same model. Pooled OR 1.34, **I²=85.6%**, still a preprint. | Weak. No feature. |
| **8** | **Stage percentages → anything** | Low REM% → mortality HR 1.13 ([Leary 2020](https://europepmc.org/article/MED/32628261)) — but in 76-y-old men, and REM is suppressed by depression, antidepressants, alcohol and OSA, each independently fatal. SWS → dementia **HR 1.27 on 52 events**. The one experimental result is [Tasali 2008](https://europepmc.org/article/MED/18172212): SWS suppression with TST preserved ⇒ insulin sensitivity **−25%**, n=9. | **Do not headline.** §3 closes this off on accuracy grounds too. |

### The finding that should shape the product voice

Van Dongen's most product-relevant result is not the dose–response curve. It is the **dissociation**: subjective sleepiness *saturated* while objective performance kept degrading linearly, and the 6 h and 4 h arms were **statistically indistinguishable on self-rated sleepiness (F=0.10, p=0.75)** while their measured performance diverged steadily.

People chronically restricted to 6 h feel about as bad as people at 4 h, and neither can feel how impaired they are. That is the honest case for measurement, it is better than "optimize your deep sleep," and Wythin can make it without accurate staging.

Second: between-subject SD for the critical wake duration was **3.58 h** (implied need 8.16 ± 0.73 h), and trait vulnerability is **stable within person and unpredicted by baseline functioning** ([Van Dongen 2004](https://europepmc.org/article/MED/15164894)). Population thresholds are the wrong tool — the same conclusion the exercise report reached, carried over unchanged.

---

## 3. Why we should refuse to show a stage pie chart

Independent 2025 validation, six devices, n=62, simultaneous PSG, no manufacturer funding ([*SLEEP Advances* 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC12038347/)):

| Device | 4-stage κ | Wake specificity |
|---|---|---|
| Apple Watch Series 8 | **0.53 ± 0.16** (n=20) | 52.2% |
| Fitbit Sense | 0.42 | 48.8% |
| Fitbit Charge 5 | 0.41 | 47.5% |
| Whoop 4.0 | 0.37 | 40.1% |
| Withings ScanWatch | 0.22 | 31.1% |
| Garmin Vivosmart 4 | **0.21** | 29.4% |

Sleep *sensitivity* is 91.7–96.3% across all six — excellent at noticing you are asleep, near-useless at noticing you are awake. That asymmetry has not moved in over a decade: wake specificity was **33%** in [Marino 2013](https://pubmed.ncbi.nlm.nih.gov/24179309/) (232,849 epochs) and **18–54%** across seven devices in [Chinoy 2021](https://academic.oup.com/sleep/article/44/5/zsaa291/6055610). Garmin's Fenix 5S posted sensitivity 0.99 / specificity 0.18 — it calls almost everything sleep, and overestimated TST by **+43.7 min**.

Pooled bias across 24 studies / 798 patients ([JCSM 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC11874098/)): TST **−16.9 min**, efficiency **−4.7%**, WASO **+13.3 min**.

Three cautions before anyone proposes a staging model:

- **Published accuracies are inflated by dataset composition.** An "easy-to-classify wake" baseline explains much of reported neural-network AUROC, and models trained without OSA subjects degrade on sleep-disordered cohorts ([*Sleep Adv* 2026](https://pmc.ncbi.nlm.nih.gov/articles/PMC13283449/)).
- **Manufacturer evaluations beat independent ones.** Samsung's own RNN reports κ 0.56; the independent evaluation of Samsung/Withings hardware lands at 0.22.
- **The human ceiling is lower than people think.** Inter-rater κ for manual 5-class scoring is **0.76** overall, and **N1 is 0.24** ([Lee 2022 meta, 11 studies](https://pmc.ncbi.nlm.nih.gov/articles/PMC8807917/)). At 5-second resolution human-vs-human falls to **0.51–0.57**. N1 is unrecoverable from cardiac signals by anyone.

**Verdict.** A stage breakdown at κ ≈ 0.4 is precise enough to be believed and wrong often enough to mislead — and §2 established stage percentages predict nothing robustly. "You got 47 minutes of deep sleep" invites exactly the causal reasoning we cannot support, on a quantity we cannot measure. Same call the exercise report made about opaque composites, made the same way: **honest absence over confident fiction.**

If staging ships, it ships as a **coarse three-state** read (wake / quiet sleep / active sleep) with agreement statistics printed beside it. Not a pie chart. Not minutes-of-deep.

---

## 4. Modelling a night — where it fits the codebase and where it breaks

### The verdict: a fourth `ActivityClass`, not a tenth `ActivityType`

Adding `case sleep` costs five lines and the compiler forces the `ActivityClass` switch (`Metrics/ActivityClass.swift:53-65`). That is the cheap path and it is wrong: every window, fetch limit, day-grouping rule and scoring formula in `ActivityLog.swift` assumes a **minutes-long, intra-day, before/during/after-shaped** event.

Reuse: the record, the sync path (type-agnostic), the server schema (`activity_type` is free-text `TEXT` — **no server migration**). Fork: the analysis, the window constants, the UI.

### Silent failures to fix first

These ship as plausible-looking wrong numbers, not as errors:

| Defect | Location | Effect on an 8-hour night |
|---|---|---|
| `desc.fetchLimit = 10_000` in `computeHRVWindows` | `ActivityLog.swift:453` | At 2 s ticks this is **5.5 hours**. A night silently truncates. |
| Fixed −300 s / +600 s before/during/after windows | `ActivityLog.swift:443-444` | No meaningful 5-minute "before" exists for sleep, and an 8-hour "during" mean flattens the architecture of the night — the only thing worth measuring. |
| `computeRecoveryTiming` 4 h horizon, `fetchLimit = 20_000` | `ActivityLog.swift:707,713` | Wrong construct entirely. |
| `DailyAnchor.day = startOfDay(startedAt)` | `DailyAnchor.swift:9` | A 23:00–07:00 span cannot be represented; the night lands on the previous date. |
| `ActivitiesView.dayGroups` groups on `startOfDay(startedAt)` | `ActivitiesView.swift:44` | Same in the UI. Server buckets by **UTC** day (`mcp_server.py:201-203`) — a known documented discrepancy. |
| `activityInProgress = true` all night | `NudgeEngine.swift:83` | **Mutes the entire nudge engine overnight** and calls `durations.interrupt()`. |
| Off-body standby fuser scores dead-still ACC **+1 toward off-body**; `contact == true` only −1 | `AppEnvironment.swift:783-817` | A motionless sleeper accumulates toward standby. Overnight capture fights the power-saving logic. |
| Picker grid sized "exactly three rows" | `ActivityFormSheets.swift:326-330` | 9 tiles + Sleep = 10 breaks the layout. |
| `currentVersion = 8` backfill counter | `ActivityLog.swift:417` | Any new stored field is **invisible on existing rows** unless bumped to 9. |

### The anchor collision — the real design decision

`AnchorThresholds.earliestAnchorHour = 4` exists *specifically* to keep sleep out of the morning anchor, and the comment (`AnchorDetector.swift:35-44`) says why: *"Sleep is the stillest, cleanest signal there is, so an overnight stretch outscores every waking rest and would be labelled the morning read — and a history mixing hour≈1 and hour≈7 anchors fails `PotentialScore`'s hour-tolerance check."*

Correct, and it should not be relaxed. It is also an admission that **the best signal the app ever collects is currently discarded.** Three options:

- **(a) Sleep replaces the anchor.** Rejected — breaks `PotentialScore.maxHourDeviation = 4` and `AnchorBaseline.hourTolerance = 2 h`, and destroys 60 days of baseline comparability.
- **(b) Fully disjoint.** Safe, wastes the asset.
- **(c) Sleep *explains* the anchor — recommended.** The night gets its own metrics on its own baseline; the morning anchor is untouched; the night becomes what the anchor is *attributed to*. *"Your morning RMSSD is 18% below your usual — the night before showed a late HR nadir and elevated resting HR from 01:00."* Preserves every invariant, needs no threshold change, better product.

The detector's machinery (still-window runs, `maxStirSec = 45`, `maxGapCeilingSec = 120`, confidence tiers) is directly reusable as an overnight segmenter under a **separate threshold set** — same code, sleep-specific constants.

### `PracticeState.sleep` already exists

The catalog has an "Improve Sleep" goal with **zero practices mapped** (`PracticeCatalogTests.swift:93`). Pre-built hook for §7.

---

## 5. What a chest ECG strap uniquely offers versus PPG

### 5a. For staging, the answer is: essentially nothing. Confront this first.

One study recorded PSG ECG, a **Polar H10**, and an arm PPG sensor **on the same nights in the same subjects** and ran the same model on all three ([Topalidis 2023, *Sensors* 23(22):9077, n=136](https://pmc.ncbi.nlm.nih.gov/articles/PMC10674316/)):

| IBI source | 4-class κ |
|---|---|
| Gold-standard PSG ECG | 0.798 ± 0.08 |
| **Polar H10 (chest ECG)** | **0.772 ± 0.09** |
| Polar Verity Sense (arm PPG) | **0.772 ± 0.10** |

**H10 vs arm PPG: not significantly different.** Worse, the H10 produced **2.1% bad IBI epochs overnight versus 0.66% for the arm PPG** — the chest strap was three times worse on nocturnal signal quality.

Every paired comparison agrees the staging gap is small and contingent:

| Study | n | ECG κ | PPG κ | Δ |
|---|---|---|---|---|
| [van Gilst 2020](https://pmc.ncbi.nlm.nih.gov/articles/PMC7653690/) | 389 paired clinical | 0.60 | 0.56 (wrist) | 0.04 |
| [Radha 2021](https://pmc.ncbi.nlm.nih.gov/articles/PMC8443610/) | 101 paired nights | 0.62 | 0.57 (wrist) | 0.05 |
| Topalidis 2023 | 136 | 0.772 | 0.772 (arm) | **0.00** |
| Radha 2021 **with transfer learning** | 101 | 0.62 | **0.65** | **−0.03 (PPG ahead)** |
| [Wulterkens 2021](https://pmc.ncbi.nlm.nih.gov/articles/PMC8253894/) purpose-trained wrist | 244+48 clinical | — | **0.62** | PPG ahead |

And [SleepPPG-Net](https://doi.org/10.1109/JBHI.2022.3225363) reaches **median 4-class κ 0.75 from raw wrist PPG** (n=2,374) — above every published ECG-IBI result against human scoring.

**The 0.2–0.35 κ gap between a good H10 pipeline and a Whoop is an algorithm gap, not an electrode gap.** State this internally before anyone builds a roadmap on "our sensor is better."

What *is* directly measured in the H10's favour: [Blalock 2026](https://doi.org/10.1016/j.autneu.2026.103447) (n=43, simultaneous criterion ECG) found **CCC ≥ 0.99 for mean RR, RMSSD and SDNN, MAPE < 1%, LoA −1.5 to +1.7 ms** — "effectively interchangeable with laboratory ECG." Against that, PPG pulse intervals inflate **RMSSD by 40%, pNN50 by 141%, HF power by 37%, SD1 by 40%** ([Mejía-Mejía 2021](https://pmc.ncbi.nlm.nih.gov/articles/PMC8121822/), 4,937 paired segments). The mechanism is structural — PPI = RR + Δ(pulse arrival time), and PAT is modulated at respiratory frequency by blood pressure and vasomotor tone.

That matters for **features, not for staging**: across 127 HRV features computed from simultaneous overnight ECG and wrist PPG, mean correlation was **0.76 ± 0.17**, but nonlinear structural descriptors collapsed to **r = 0.07–0.31** (visibility-graph degree slope r = 0.069). Entropy, visibility-graph, Teager-energy and fragmentation features are **only available from ECG-grade RR**. That is a real and defensible moat — for the metrics in §6, not for the hypnogram.

### 5b. Where the chest strap genuinely wins: respiratory effort

A sternum accelerometer is mechanically where a respiratory-effort belt goes. The Philips/Eindhoven programme built an entire overnight apnea pipeline from **one tri-axial accelerometer on the thoracic belt** — almost exactly the H10's position.

[Schipper 2023, n=146 (hold-out 72), 610 h, 146,283 observations, 100% coverage](https://doi.org/10.1016/j.bspc.2023.104726):
- **Median Pearson correlation with the RIP belt ≈ 0.94–0.95**
- **Breath-by-breath detection: sensitivity 98.4%, PPV 98.2%**
- Degrades with leg movements (r 0.96 → 0.83) and during SDB events (0.95 → 0.87)
- **Respiration is a gravity-vector tilt signal in the plane orthogonal to g** — estimate gravity, work in that plane; there is no privileged device axis
- **Low-passed and decimated to 10 Hz** before the model. Anything ≥25 Hz sampling suffices.

Full AHI estimation from chest accel alone ([Schipper 2026, *Frontiers in Sleep*, n=413, hold-out 207](https://www.frontiersin.org/journals/sleep/articles/10.3389/frsle.2026.1858267/full)):

| Metric | Value |
|---|---|
| **AHI ICC vs PSG** | **0.90 (0.86–0.92)** |
| Bias | −0.07 events/h |
| 95% LoA | −14.60 to +14.46 |
| 4-class severity κ | **0.76** |
| Staging κ (4-class) | 0.665 |

Their LoA sits *inside* the range reported for CPAP machines' own AHI, and their likelihood ratios beat peripheral arterial tonometry. Ablation worth noting: transfer learning gave ICC **0.90**, training from scratch on accel features **0.79**, naively applying an ECG+RIP model **0.58**. You cannot swap the input modality for free.

**Adding respiration to ECG is the single largest lever available.** [Sun 2020, *Sleep*, 8,682 PSGs](https://pmc.ncbi.nlm.nih.gov/articles/PMC7355395/):

| Input | 5-stage κ | W/NREM/REM κ |
|---|---|---|
| ECG R-peak timing alone | 0.490 | 0.637 |
| **ECG + chest effort** | **0.586** | **0.730** |
| ECG + abdominal effort | 0.585 | **0.760** |

**+0.10 κ (5-stage), +0.12 κ (3-class) — larger than any feature-engineering gain in the literature.** Wythin has two independent respiratory channels (`BreathingCompute` from the accelerometer, `EDRCompute` from RR) and uses neither for sleep.

### 5c. Obstructive versus central — the thing PPG structurally cannot see

Effort amplitude *is* the obstructive/central axis. Measured against esophageal pressure with a jaw sensor, median effort amplitude ran **0.60 (central apnea) < 0.83 (central hypopnea) < 1.93 (mixed) < 3.23 (obstructive hypopnea) < 6.42 (obstructive apnea)** — a monotonic ~10× spread ([*Nat Sci Sleep* 2022, n=38, 8,042 blocks](https://pmc.ncbi.nlm.nih.gov/articles/PMC9013709/)).

Know the ceiling and the asymmetry:
- Gold-standard **RIP belts vs esophageal pressure reach only κ 0.87**, central-event sensitivity 87.5%. An accelerometer cannot beat the belt it was trained on.
- Clinical multi-patch systems get obstructive apnea index **r = 0.86** but central **r = 0.78** — central is the weakest channel even for research hardware ([Onera, n=206](https://pmc.ncbi.nlm.nih.gov/articles/PMC13244203/)).
- Chest+abdomen accel CNN F1: **central 87%, obstructive 51%.** *Absence* of effort is unambiguous; *continued effort without airflow* requires inferring airflow you cannot see.

**A free second effort channel:** high-pass-filtered ECG with QRS blanking reveals **inspiratory EMG bursts in 83% of 250 studies**, and blinded apnea classification from transformed ECG vs RIP achieved **88.5% agreement, κ 0.81** ([JCSM 2019](https://pmc.ncbi.nlm.nih.gov/articles/PMC6622518/)). The H10 has a 130 Hz sternal ECG. This costs no hardware and fuses naturally with the accelerometer channel.

**What is not possible:** thoracoabdominal paradox needs *two* compartments (ribcage and abdomen). One sternal sensor cannot measure a phase angle. That would be a second device.

### 5d. Body position — the highest-confidence capability, and wholly unavailable at the wrist

Sleep position is torso roll about the body's long axis. A sternum gravity vector *is* that angle. A wrist gravity vector is the forearm's angle, and the forearm has three joints and ~300° of freedom relative to the trunk — **the mapping is not merely noisy, it is non-injective.** No ML fixes that without an auxiliary signal. Accordingly there is **no published 4-class sleep-position accuracy from a wrist accelerometer**; the best wrist papers claim posture *change* detection (F1 99.2%) and never name the position.

Expect the garment number, not the lab number:

| Mounting | Accuracy |
|---|---|
| Rigid trunk sensor vs video (n=90) | **κ 0.95**, per-class 95–99% |
| **Hexoskin garment vs video (347 h)** | **balanced accuracy 0.76** — supine 75%, **prone 65%**, right lateral 94% |

Prone-vs-supine is a ±180° flip about the strap's long axis; a rotated strap makes it a coin flip. Also: a four-class scheme throws away a lot — a sternum study found only **59.7% of TST within ±15° of a canonical position**. Report continuous roll, not four bins.

**Why it is worth doing.** In SHHS (n=1,870 with AHI ≥5), **62% of OSA is positional** by the Cartwright criterion, with median supine:non-supine AHI ratio **4.8×** (and **10.1×** for the supine-isolated subtype). Patients cannot self-report it: of those who *denied* sleeping supine, only **56% were right**, with **11.0× the odds** of misperceiving.

And the sharpest unmet need: **15% of lab-diagnosed positional OSA patients never sleep supine at home at all**, and one real-world trial found only 19 of 102 PSG-diagnosed POSA patients met an at-home supine criterion. A multi-night home chest strap answers the question the sleep lab structurally cannot — *does this person actually sleep supine, and how much* — at essentially zero marginal cost.

### 5e. Seismocardiography — a redundancy channel, plus one novel signal

At 200 Hz the H10 has 100 Hz Nyquist and SCG needs 3–25 Hz. Sampling is solved; noise floor is the open question. Overnight, from a chest accelerometer ([Schipper 2024, n=147, 3.5 M beats](https://doi.org/10.1088/1361-6579/ad2f5e)): **IBI MAE 3.5 ms, PPV ~100%, sensitivity 88.9%** per motion-free segment, **HR LoA −1.65 to +1.03 bpm** — but **coverage only ~75–80%**.

Since the H10 already streams ECG, SCG's value is (a) a **fallback when electrode contact fails** — which §5g says will happen a lot — and (b) something genuinely novel: **the hemodynamic cost of each respiratory event.** During simulated obstructive events, SCG rotational kinetic energy rose from 1.1 to **1.9 µJ·s** (p<0.001), and during real end-expiratory apnea, BCG kinetic energy correlated with muscle sympathetic nerve activity at **r = 0.85**. No consumer device quantifies the afterload surge and sympathetic burst *per event* rather than counting events.

### 5f. Snoring: out of scope

Dominant snore energy sits at **300–1100 Hz**; the palatal first spectral peak is typically 150–265 Hz. At 200 Hz sampling (100 Hz Nyquist) all of that is unreachable — and unless the H10 hard anti-alias filters below 100 Hz, snore energy will **fold down into the 3–25 Hz SCG band** and contaminate beat detection. The sternum is also the wrong site; tracheal/suprasternal is where snore vibration transmits. Use the phone microphone or skip it.

### 5g. The honest counter-case

| Loss vs a wrist PPG device | Consequence |
|---|---|
| **No SpO₂** | No ODI, no T90, and **no hypoxic burden** — the metric that beat AHI outright for CV mortality (§9). The strongest single argument for adding one sensor. |
| **No skin temperature** | No circadian-phase proxy, no illness/ovulation signal. |
| **Overnight signal quality** | The companion form-factor doc already measured this: in a textile-belt cohort of **n=242 overnight**, **49.7% of the recording was worst-class**, and only ~45% of an overnight recording is Class 1+2 (where >99% of segments give accurate RR). Topalidis independently found H10 bad-IBI epochs at 3× the arm PPG rate. Hexoskin degraded **94.9% → 80.0%** across 24 h — a *drying* curve. |
| **Chest actigraphy is worse than wrist** | The torso moves less; wake detection from trunk motion is weaker. |
| **Compliance** | Nobody has published overnight chest-strap wear tolerance at scale. Assume it is the binding constraint on the whole programme. |

**The unmeasured number that decides the roadmap:** overnight H10 IBI completeness, on a self-applied strap, across a full night. Every capability above is conditional on it, and it does not exist in the literature. Measure it before committing.

### 5h. Capability matrix

| Capability | H10 today | H10 + SpO₂ | Wrist PPG | PSG |
|---|---|---|---|---|
| Beat-to-beat RR at ECG quality | ✅ (LoA ±1.5 ms) | ✅ | ⚠️ inflates RMSSD 40% | ✅ |
| Nonlinear IBI features (entropy, fragmentation, visibility graph) | ✅ | ✅ | ❌ (r 0.07–0.31) | ✅ |
| 4-class staging | ⚠️ κ ~0.6 realistic | ⚠️ | ⚠️ κ 0.21–0.53 shipped | ✅ κ 0.76 human |
| **Respiratory effort waveform** | ✅ **r 0.94** | ✅ | ❌ | ✅ |
| **Obstructive vs central** | ✅ directionally | ✅ | ❌ | ✅ κ 0.87 |
| **Body position** | ✅ ~0.76 bal. acc. | ✅ | ❌ non-injective | ✅ |
| Per-event autonomic response (ΔHR) | ✅ | ✅ | ⚠️ | ✅ |
| Per-event hemodynamic cost (SCG) | ✅ novel | ✅ | ❌ | ❌ |
| **ODI / hypoxic burden** | ❌ | ✅ | ✅ | ✅ |
| Circadian phase proxy (temperature) | ❌ | ❌ | ✅ | — |
| Nightly compliance | ❌ worst | ❌ | ✅ best | ❌ |

---

## 6. Overnight autonomic recovery — what to actually compute

### 6a. The vagal metrics everyone displays are the wrong stage features

[Herzig 2017, n=15, 45 nights, 1,792 five-minute segments](https://pmc.ncbi.nlm.nih.gov/articles/PMC5767731/), medians:

| Parameter | Stage 2 | **SWS (N3)** | **REM** | N3-vs-REM |
|---|---|---|---|---|
| HF power (ms²) | 1095 | 1167 | 1322 | **no separation** |
| RMSSD (ms) | 70.7 | 67.3 | 79.7 | **no separation** |
| **LF power (ms²)** | 1303 | **651** | **2541** | **4×** |
| **SDNN (ms)** | 68.5 | **53.8** | **105.5** | **2×** |
| **LF/HF** | 1.11 | **0.51** | **2.02** | **4×** |

**RMSSD and HF — the metrics users expect — barely separate deep sleep from REM.** But they are the *most reproducible* things measurable in SWS (ICC 0.84 for both), while LF and LF/HF have ICC 0.42–0.54 and poor between-night reliability.

That splits cleanly into a product rule: **use LF/SDNN to find the stage; report RMSSD/HF within it.** A trend metric and a classifier feature are different jobs.

**And a nearly free N3 detector:** the lag-1 autocorrelation of consecutive RR intervals over a 5-min moving window (`rRR`), detrended, first sustained drop ≥0.1 below its mean — **87% of selected segments fell entirely inside SWS** (39/45 nights). No spectral estimation, no detrending pathology. Prototype this first.

### 6b. Cardiorespiratory coherence is the strongest stage discriminator published — and it is already built

`CoherenceCompute.swift` computes RR↔breath magnitude-squared coherence today, for waking use. In sleep ([Migliorini 2012, n=11, per cycle](https://pmc.ncbi.nlm.nih.gov/articles/PMC3299415/)):

| Cycle | Wake | N2 | **N3** | **REM** |
|---|---|---|---|---|
| 1 | 0.767 | 0.814 | **0.949 ± 0.06** | 0.816 |
| 2 | 0.381 | 0.867 | **0.962 ± 0.04** | 0.686 |
| 4 | — | 0.885 | **0.965 ± 0.03** | 0.747 |

N3-vs-REM **p = 3.339 × 10⁻⁵** — two orders of magnitude smaller than any other measure in the same subjects (next best: HF n.u. at 0.0012). Replicated directionally in children (NREM 0.80 vs REM 0.52).

Related and even larger: cardiorespiratory **phase** synchronization shows a **400% increase** from REM/wake to light/deep sleep, and **the stage difference exceeds the young-vs-elderly difference** ([Bartsch 2012, *PNAS*](https://pmc.ncbi.nlm.nih.gov/articles/PMC3387128/)). It is explicitly *orthogonal* to RSA.

Note the framing caution: Thomas' ECG-based cardiopulmonary coupling agrees with standard staging only **43.9–62.7%** but with **cyclic alternating pattern scoring at 74–77.3%**. CPC is a sleep-*stability* measure, not a stage classifier — NREM is bimodal (stable vs unstable), not graded. Evaluate it against stability, never against a hypnogram.

### 6c. DFA: use α2, not α1

[Schumann 2010, n=180, 346 nights, 7 labs](https://pmc.ncbi.nlm.nih.gov/articles/PMC2894436/), ages 20–39:

| Exponent | Wake | Light (S2) | Deep | REM |
|---|---|---|---|---|
| **α1** (short) | 1.12 | 0.96 | 0.80 | 1.11 |
| **α2** (long, 50–200 s) | 1.02 | **0.65** | **0.59** | **0.88** |

α2 separates NREM from REM at **d ≈ 1.9–2.2**; α1 manages **d ≈ 1.1** for deep-vs-REM and **d = 0.04 for wake-vs-REM — no discrimination at all.** α2 is also insensitive to sex, BMI, smoking and, critically, **to OSA at any AHI stratum**. α1 is confounded by age (peaks at 50–60), by sex (p<0.001), and is **77% explained by ln(VLF/HF)**.

Wythin computes α1 over scales 4–16. Adding α2 over 50–200 s is a small change with a large return.

### 6d. The two best overnight *prognostic* metrics are already implemented

This is the report's strongest finding for existing code. [HypnoLaus, n=1,784, 4.1 y, 67 incident CVD events](https://doi.org/10.1016/j.hrthm.2021.11.033) computed time-domain, frequency-domain, Poincaré, DFA, entropy, turbulence, AC/DC and fragmentation. **After FDR correction only three survived:**

| Metric | HR per 1 SD |
|---|---|
| Acceleration capacity | **1.59 (1.17–2.16)** |
| **Deceleration capacity** | **0.63 (0.47–0.84)** |
| **Heart rate fragmentation** | **1.41 (1.11–1.78)** |

**Every time-domain and frequency-domain HRV parameter was non-significant.** Authors' words: novel parameters "are better predictors of CVD events than time and frequency traditional HRV parameters."

Wythin already computes DC (PRSA, Bauer 2006) and PIP/IALS in `AdvancedHRVCompute.swift`.

**DC — get the thresholds right.** The published tertiles are **>4.5 ms normal / 2.6–4.5 intermediate / ≤2.5 ms severely abnormal**. In a general population (n=823, 5-min ECG, 13.4 y), 13-year mortality ran **16.7% / 23.5% / 49.1%**, HR 2.34 for the worst category. [Bauer 2006, *Lancet*](https://doi.org/10.1016/S0140-6736(06)68735-7) post-MI: **AUC 0.80 vs LVEF 0.67 and SDNN 0.69.**

**Fragmentation — the nocturnal evidence is unusually good, and it is all overnight-ECG-derived.** [Costa 2017](https://pmc.ncbi.nlm.nih.gov/articles/PMC5422439/), nocturnal AUC for CAD: **PIP 0.806, IALS 0.804**, versus RMSSD 0.653, HF 0.653, SampEn 0.591, and **DFA α1 0.521 — chance.** In MESA (all from PSG ECG): incident CV events **HR 1.43**, CV death **1.65**, incident AF **+31%**, and MACE **+60% in people with zero coronary calcium**.

Two cautions. Overnight **DC and PIP do not track OSA severity** (n=157) — they are cardiac-risk metrics, not apnea metrics. And a 2026 tilt/paced-breathing study found PIP correlates with symbolic 2UV at **r = 0.74** and shifts with breathing rate, **challenging the view of fragmentation as autonomic-independent**. If you report PIP, control for respiration rate — which the H10 measures two ways.

**Do not market nocturnal DFA α1 as a cardiac metric.** Good stage marker, AUC 0.52 for disease.

### 6e. Two open publishable gaps Wythin is positioned to fill

- **Heart rate fragmentation stratified by sleep stage: zero prior papers.** Day/night differences are published (PAS 1.85% night vs 4.36% day); per-stage values do not exist.
- **RCMSE by sleep stage: zero prior papers.** Wythin already computes RCMSE.

Both require per-stage segmentation the app would build anyway. If pursued, control for breathing rate.

### 6f. Respiratory rate is the most stable overnight metric — and a terrible alert

Within-person nightly SD is **0.51 breaths/min (CV 3.28%)**, versus RHR CV 8.60% and RMSSD CV **27.2%** ([Miller 2020, 30 nights](https://doi.org/10.1371/journal.pone.0243693)). RR is ~8× more stable than HRV. Population mean 15.4/min, 90% of healthy adults 11.8–19.2 ([n=10,000](https://doi.org/10.1038/s41746-021-00493-6)). Stability degrades markedly with age.

Clinically, RR is the best single vital sign for deterioration (AUC 0.72 vs HR 0.68; [Churpek 2012](https://doi.org/10.1378/chest.11-1301)), and nocturnal RR median + within-night variability independently predicted mortality in SHHS.

**But do not build an alert on it.** The one prospective, real-world, tested-alert study — 470 healthcare workers required to get a viral panel when alerted — produced **665 alerts, 512 panels, 63 infections: PPV 4–10%**, with a false-positive rate of ~2% of days ([Esmaeilpour 2024](https://doi.org/10.2196/53716)). That is **~7 alerts per person-year, 90–96% of them wrong**, and the wrong ones are driven by exercise, poor sleep, stress and alcohol. Fitbit's own data: only **36.4% of symptomatic COVID cases** ever had a night ≥3 breaths above baseline.

**Ship RR as a retrospective explanatory variable, never as a trigger.** "Your breathing rate was 1.8 above your baseline last night" — with the alcohol you logged sitting next to it.

### 6g. Do not ship a recovery score

- **No RCT anywhere tests a commercial recovery/readiness score as an intervention.** Oura and WHOOP appear in trials as *measurement instruments*, sometimes with participants deliberately blinded to the score.
- Under **deliberate training overload**, subjective metrics degraded while **wearable nightly recovery metrics showed no consistent change** ([Nuuttila 2025, n=24](https://doi.org/10.3390/s25020533)).
- Self-reported stressed vs not: HRV **63.5 vs 63.1 ms, p=0.63**. Feeling *energized* was associated with **lower** HRV ([Ungaro 2026, n=39](https://doi.org/10.3390/s26041325)).
- The interpretive killer: vagal HRV rises with **both** positive adaptation and functional overreaching ([Bellenger 2016 meta](https://doi.org/10.1007/s40279-016-0484-2)). A single number cannot resolve that ambiguity, and no vendor discloses how they try. *(This is the same conclusion the exercise report reached about composites — it holds for sleep.)*
- **Subjective beats objective.** Across 56 studies, subjective measures tracked training load with **superior sensitivity and consistency** than every objective marker ([Saw 2016, *BJSM*](https://doi.org/10.1136/bjsports-2015-094758)). And HRV+subjective outperformed HRV alone in a 3-arm trial.
- HRV-guided training works, but modestly: endurance performance **SMD 0.20 (−0.09 to 0.48)**; the real benefit is **fewer negative responders**, not higher peaks ([Manresa-Rocamora 2021](https://doi.org/10.3390/ijerph181910299)).

**Design against orthosomnia.** Users report *"more of an emotional response rather than a rational one"* to a daily score and adjust behaviour to improve **the number** rather than their health. Measured prevalence 3.0–14.0% depending on criterion. Aggregate over ≥7 nights, avoid daily red/amber/green, and **version-stamp every derived metric** so history can be re-derived when the model changes — algorithm churn silently breaks longitudinal comparability, and the same Oura hardware produces materially different architecture under different algorithm versions.

---

## 7. Recommendations that can be auto-triggered

**The strategic finding first, because it is uncomfortable.** Wythin's two signature features have the weakest sleep evidence in this entire report. Slow breathing improves *self-reported* sleep with objective data rated inconclusive. The landmark cyclic-sighing trial measured sleep and HRV directly and found **neither** moved. Relaxation is the one CBT-I component the component network meta-analysis flags as **possibly counterproductive**. And breath-hold training has no sleep evidence base at all — while the hold duration we already measure turns out to be a validated marker of an OSA endotype, pointed the wrong way.

That is not an argument for removing them. It is an argument for selling them as what the evidence supports — mood, stress, ritual, adherence — while building the *sleep* engine on regularity, alcohol, exercise timing and thermal, which is where the RCTs actually are.

Evidence grades below: **A** = meta-analysis of RCTs, or lab RCT plus concordant large within-person data. **B** = large within-person observational plus coherent small trials. **C** = single small trial. **X** = folk wisdom, or evidence absent or inverted.

### 7a. Ship first — the rules with both good evidence and a real trigger

| Intervention | Evidence | Trigger (H10 only) | Confirmation + horizon |
|---|---|---|---|
| **Fixed / gradually-advancing wake time** | **A, and it beats light.** Saxvig 2014 (n=40 DSPD, 4 arms): DLMO advanced **~2 h in all four arms including dim-light + placebo** — bright light and melatonin added nothing detectable. Regularity outcome: SRI Q5 vs Q1 all-cause mortality **HR 0.70**, and SRI beat duration (§2). | SRI < ~70 over ≥5 contiguous valid nights (UK Biobank median is 81), or sleep-onset SD > 60 min | SRI over rolling 14-night windows; **28 nights** for two non-overlapping windows |
| **Alcohol — reduce the count** | **A, the flagship.** Lab PSG crossover (n=26): nocturnal HR **+~4%** low dose, **+~14%** high. Pietilä 2018 (**n=4,098**, ECG, first 3 h): HR **+1.4 / +4.0 / +8.7 bpm**, RMSSD **−2.0 / −5.7 / −12.9 ms** by dose. Grosicki 2026 (**n=20,968, 5.1 M person-days**): one drink above personal average ⇒ RHR **+2.8 bpm**, HRV **−3.8 ms**. | Logged drinks **+** first-3-h HR ≥ baseline +3 bpm **+** first-3-h RMSSD ≤ baseline −3 ms **+** delayed/shallow HR nadir **+** LF/HF *rising* hour-by-hour instead of falling (the high-dose fingerprint) | ~2.5 bpm and ~3.5 ms per drink; **10–14 paired nights** |
| **Finish hard sessions ≥4 h before sleep onset** | **B+, enormous n.** Leota 2025 (*Nat Commun*, 14,689 people, **4,084,354 person-nights**): ending **≥4 h before onset shows no sleep change at any strain**. Maximal vs light ending 2 h pre-onset: onset **+36 min**, TST **−22 min**, nocturnal RHR **+3.9 bpm**, RMSSD **−8.3 ms**. Ending *after* habitual onset: RHR **+9.4 bpm**, RMSSD **−14.6 ms**. | Session end time + strain ≥ personal 70th pct + first-90-min nocturnal HR ≥ baseline +3 bpm | Nocturnal mean HR **−3 to −4 bpm**, first-3-h RMSSD **+6 to +8 ms**; **21–28 nights** |
| **Stop avoiding evening exercise as such** | **A.** Stutz 2019 meta (23 studies): *"the studies reviewed here do not support the hypothesis that evening exercise negatively affects sleep, in fact rather the opposite."* Sleep & Breathing 2025 meta (14 studies, n=716): **no significant association between exercise timing and any sleep outcome.** | User avoids post-17:00 sessions | None needed — this is a de-restriction, and the highest-confidence item here |
| **Warm bath/shower 40–42.5 °C, ≥10 min, 1–2 h before bed** | **A.** Haghayegh 2019 meta (17 studies): that exact temperature window, that exact timing, ≥10 min ⇒ shorter onset latency, better efficiency and self-rated quality. Mechanism is distal skin warming widening the distal-proximal gradient — **the best single predictor of sleep onset**. Dose matters: +0.9 °C worked, **+0.3 °C did not**. | Estimated SOL > 20 min on ≥3 of 7 nights, or bedtime HR still > 8 bpm above the eventual nadir 30 min after lights-out | Estimated SOL, time-to-HR-nadir, first-2-h RMSSD; **10–14 paired nights**. Do not promise slow-wave sleep |
| **Evening light ≤10 melanopic EDI lux, 3 h pre-bed** | **A dose-response.** Gooley 2011 (n=116): <200 lx room light delayed melatonin onset in **99.0%** of people. Phillips 2019 (n=55): group **ED50 = 24.6 lx**, but individual ED50 spans **6–350 lx** — a >50-fold range. | Sleep onset ≥30 min later than personal median on ≥3 of 7 nights | Sleep onset earlier and less variable; **14–21 nights**. Ship the conversion: mel-EDI ≈ lux × DER, DER ≈ 1.0 daylight, ~0.5–0.6 for 4000 K LED, **<0.35 warm-white** |
| **Postprandial masking window (internal rule)** | **A.** A standard meal elevates HR from 40 min, suppresses HF **40–120 min**, elevates LF/HF **20–120 min**. High-fat meal HR **+7.8 bpm**. | Any logged meal opens a 3-hour window | **Use it to suppress HRV scoring, not to score.** Highest-value internal rule in this section |
| **Nap ≤20 min, early afternoon** | **A.** Brooks & Lack 2006 (PSG, n=24): **10 min optimal**, benefits lasting up to 155 min; 20-min benefits only emerge after 35 min. Meta (11 studies): alertness g **0.29**. In older adults a month of daily 45-min or 2-h naps did **no** harm to night sleep — do not blanket-ban naps. | Prior-night duration ≥60 min below personal median, or morning anchor down, and no nap logged | Evening estimated SOL unchanged vs no-nap days; **≥12 nap/no-nap pairs**. Add a 30-min inertia buffer for longer naps |

### 7b. The breath-hold inversion — the most valuable finding in this report

The app ships `HoldProtocol.standard` — 20 s holds **on empty**, five sets, framed in the catalog as CO₂-tolerance training ("the urge to breathe is a response to that CO2… this trains the tolerance"). The sleep literature reads that same number in the opposite direction.

**Messineo 2018 (*J Physiol*, 10 OSA + 10 controls, gold-standard loop gain measured during NREM): shorter maximal breath-hold duration predicts *higher* loop gain, r² = 0.49, p < 0.001. Combined with the ventilatory response to 20-second holds, ROC AUC = 92% for detecting high loop gain.**

Loop gain is ventilatory control instability, and it is a recognised OSA endotype (§9 noted the related PPG endotype ICCs of 0.95). So:

- **In breathwork culture**, a short hold means poor CO₂ tolerance — a deficit to train away.
- **In sleep medicine**, a short hold means unstable ventilatory control — a risk marker.

**We are already collecting the input to a validated screening measure and displaying it as a fitness score.** Inverting that reading costs no new hardware and no new sensor: it is a reinterpretation of a number already on disk.

**As a training intervention, however, breath-holding has no evidence base at all.** Explicit searches returned exactly five papers linking breath-holding and loop gain — **all five use holds to *measure* loop gain; none uses them as training.** Zero results for breathing exercise × ventilatory control × sleep. And the chemoreflex data is discouraging: 14 days of daily maximal holds increased hold time ~46% while **CO₂ sensitivity was unchanged** (2.7 vs 2.7 L/min/mmHg); repeated apneas raised hold time 43% with **no change in hypercapnic ventilatory response**. Elite divers show blunted CO₂ sensitivity but a *higher* hypoxic ventilatory response (+68% at rest) — which would **raise** loop gain, not lower it.

There is also a published harm mechanism worth stating plainly: a 2025 *Epilepsy & Behavior* review names *"apnea training (swimming and diving)"* alongside OSA as plasticity inducing **"apnea comfort"** — loss of the suffocation alarm — permitting *"extended apnea without inducing alarm, arousal, or significant compensatory hyperpnea, even in healthy subjects."*

**Verdict: keep Hold Breath as a standalone practice with no sleep claim. Do not map it to `PracticeState.sleep`. Repurpose the hold-duration measurement as an OSA-risk input, subject to the §8d language constraints** — which means it informs a "breathing steadiness" trend and a soft healthcare-provider suggestion, never a disease name or a screening verdict.

### 7c. The gate that must exist before any airway-adjacent feature

Roughly 80% of OSA is undiagnosed (§9). HRV-from-ECG machine-learning OSA detection has a Bayesian meta-analysis behind it — 9 studies, 2,019 participants, **pooled sensitivity 79.0%, specificity 75.0%, DOR 11.3**, described as having *"higher specificity than STOP-BANG and comparable performance to home sleep tests."* That is enough for a risk **flag**, never a diagnosis.

Anything that alters nocturnal ventilation must sit behind: risk flag negative **AND** no snoring / witnessed apnea / BMI red flags **AND** an explicit healthcare-provider path. This gate is cheap, uses only ECG we already stream, and is the precondition for the breath-hold reinterpretation above.

### 7d. Ship with care, or ship the honest version

| Intervention | Evidence | Verdict |
|---|---|---|
| **Slow breathing ~6/min pre-bed** — we already ship `EvenCadence.resonance` at **~5.5 brpm** | **B, subjective only.** *Sleep Med Rev* 2026 SR (9 studies, n=457): self-reported duration and quality improve, but **actigraphy (n=2) and PSG (n=3) "inconclusive"** — and the objective studies ran 1 day while the positive self-report studies ran 28–30, so design confounds direction. Head-to-head (n=84): 6/min raised HRV more than box or 4-7-8 **but caused mild over-breathing**. | **Ship as a wind-down ritual with honest framing.** Do **not** claim it raises overnight HRV or increases deep sleep. Only 11 papers exist on pre-sleep breathing × nocturnal HRV and none establishes an effect. |
| **Cyclic sighing (Balban protocol)** | **A-grade RCT, null on our outcomes.** n=108, 28 days: mood **+1.89 PANAS** (p=0.025) and respiratory rate down. But **"no significant changes were found in heart rate variability or resting heart rate"** and sleep hours, efficiency and score showed **"no significant changes… in either group."** Anxiety improved no more than mindfulness. | **Ship as a mood/stress tool, explicitly not as a sleep intervention.** The trial that made this famous looked for both a sleep effect and an HRV effect and found neither. |
| **4-7-8 and box breathing** | **C.** *"Popularly promoted by psychotherapists but have little empirical support."* Both raised HRV **less** than 6/min in the only head-to-head. | Ship as user preference only. 6/min dominates. |
| **Sleep compression** | **A, and the honest nuance.** Non-inferiority RCT (n=234, *Sleep* 2025): compression **failed non-inferiority** against sleep restriction and gave smaller, slower gains (p=.006) — **but with better adherence and fewer side effects.** | **The only defensible unsupervised titration.** Weaker by design, which is the point. Hard floor on prescribed time in bed; auto-abort on daytime-sleepiness self-report. |
| **Stimulus control** | **A.** Component NMA (241 RCTs, 31,452 participants): remission iOR **1.43**. | **Ship** — best risk/benefit of any CBT-I component for an unsupervised app. |
| **Cognitive restructuring** | **A, the largest single component** (iOR **1.68**). | Ship as self-report-gated content, and say plainly that the hardware is blind to it. There is no H10 trigger for "lying awake catastrophising." |
| **IMST (30 resisted breaths/day)** | **A for blood pressure, thin for sleep.** *JAHA* 2021 sham-controlled RCT (n=36): SBP **−9 mmHg**, ~75% sustained six weeks after stopping, ~95% adherence. | **Ship as a cardiovascular feature with real RCT support.** Do not market it for sleep — that data is in OSA patients, not our users. |
| **Morning outdoor light** | **B/A mechanistic.** 1 h at 8,334 lx ⇒ fitted advance **+0.45 h**. Camping studies: DLMO **−2.0 h** over a week. The advance limb is the weak limb — 1 h buys ~40% of a delay but only **~22%** of an advance. | **Ship, framed as minutes per day**, and as an accelerator on a fixed wake time rather than a substitute for one. Cap expectations at ~0.5 h/day. |
| **Sauna** | **Timing rule B; sleep claim X.** No PSG RCT of sauna → sleep exists. Acute autonomics are large: 30 min at 87 °C ⇒ HR **+32%**, lnRMSSD **−62%**. | **Ship the ≥90-min-before-bed timing rule only.** Do not ship "sauna improves sleep." |
| **Melatonin — timing education** | **A for chronobiotic logic, tiny as a hypnotic.** Optimally timed, **0.5 mg and 3 mg produce equal phase shifts**, and 0.5 mg entrained a blind free-runner that 10 and 20 mg failed to entrain. As a sleeping pill: SOL **−7.06 min**, TST **+8.25 min**. Product safety is damning — 31 products assayed at **−83% to +478%** of label, serotonin in 8 of 31. | Ship the timing education and **the honest number (~7 minutes)**. Never "melatonin fixes insomnia." |

### 7e. Do not ship

**Never:**

- **Mouth taping.** *PLoS One* 2025 SR: 10 studies, 213 patients, **all ten rated poor quality**, meta-analysis impossible, and **4 of 10 excluded anyone with nasal obstruction**. Documented risks include asphyxia with nasal obstruction or regurgitation, and aspiration. The authors' words: *"a potentially serious risk of harm for individuals indiscriminately practicing this trend."* Recommending airway occlusion to a population that is ~80% undiagnosed for OSA is the clearest liability in this report. Not as a tip, not as a "some people try."
- **Unsupervised sleep restriction.** Kyle 2014 (PSG): during acute SRT objective TST fell **91 min**, effect sizes **1.60–1.80**, with **objectively impaired psychomotor vigilance**; ≥50% of patients reported impairment. We cannot screen, exclude or monitor for bipolar disorder, epilepsy, untreated OSA, professional drivers or shift workers.
- **Breath-holding as a sleep or breathing-health intervention** (§7b).
- **Any caffeine rule keyed to nocturnal HR/HRV — the evidence runs backwards.** The one study measuring plasma caffeine with PSG and HRV found caffeine dose-dependently **reduced heart rate (−3.24 bpm) and *increased* HF-HRV in NREM.** A "low RMSSD → blame the coffee" rule is inverted and would misattribute alcohol and training nights. Ship the log-driven cutoff (<100 mg → 4 h; 100–150 mg → ~9 h; ≥200 mg → 12–13 h) and say plainly that we cannot confirm it physiologically.
- **Any sleep-architecture attribution** — REM, deep, light — to any logged behaviour (§7f).
- **Single-night causal sentences**, at any tier.

**Not as evidence-graded advice:** blue-blocking glasses (the only 3 double-blind crossover RCTs, n=49: SOL **−4.86 min, NS**; Cochrane 2023 very-low certainty); screen night mode (Apple Night Shift tested directly — **no significant melatonin-suppression difference** at equal brightness); magnesium (3 RCTs, n=151, GRADE low to very low); glycine (n≈11, subjective, all from the same amino-acid manufacturer's group); L-theanine for sleep (subjective SOL SMD **0.15**, flagship trial manufacturer-funded); time-restricted eating for sleep (network meta-analysis: TRE showed **longer** onset latency, +9.54 min); a precise magic bedroom temperature (the popular 18.3 °C has no trial behind it); long-nap cardiovascular warnings (reverse causality — long naps more plausibly *mark* undiagnosed OSA).

### 7f. Causal inference — the discipline, and why it is stricter than it looks

**The measurement-error trap is the one that will bite us, and it manufactures effects from nothing.** Classical error merely attenuates. **Differential** error creates. Consumer devices *"tended to perform worse on nights with poorer/disrupted sleep"* — and alcohol increases awakenings, movement and tachycardia, exactly the conditions under which staging degrades. **A device that under-scores N3 when sleep is fragmented will report "less deep sleep after alcohol" even when true N3 was identical.**

> **Hard rule.** Never attribute a change in a **stage-derived** quantity (deep, REM, light, sleep efficiency, WASO) to a behaviour that plausibly perturbs movement or heart rate — which is nearly everything we log. Attribute only to **RR-interval-derived** quantities (nocturnal RMSSD, resting HR, HR nadir, DC, respiratory rate) that come straight off the ECG with no classifier in the path. This alone rules out most of what competitors say.

**The resolution floor is arithmetic and needs no assumptions.** For a paired sign/permutation test on *k* pairs, the minimum attainable two-sided p is 2·(½)^k:

| k pairs | 5 | **6** | **11** | 12 |
|---|---|---|---|---|
| Min attainable p | 0.0625 | **0.031** | **0.00098** | 0.00049 |

**Fewer than 6 pairs cannot produce p < 0.05 no matter what the data show.** With Bonferroni across 40 candidate factors (α = 0.00125), **k ≥ 11** before a claim is arithmetically possible.

**Serial correlation, not sample size, governs power.** In crossover simulations with 400 observations, power to detect a 0.3 SD effect fell from 0.851 at ρ=0 to **0.126** at ρ=0.75 with one period — but recovered to 0.681 with 40 alternating periods. **Alternation frequency matters more than total nights.** "Drink for two weeks, then don't" is near-worthless; alternating recovers most of the power.

**Regression to the mean, quantified.** Selecting the worst 25% of nights yields expected apparent improvement of **0.64 σ** at ρ=0.5 from nothing at all; for the single worst night, **0.97 σ**. Free-living nocturnal RMSSD has ~12% typical error with ρ≈0.5–0.7. **Never trigger a message off a threshold-crossing night.**

**Day-of-week is not optional.** Alcohol clusters on Friday and Saturday, and weekend sleep differs for unrelated reasons — 49.4% of adults report 1–2 h more weekend sleep. Match each exposed night to unexposed nights of the same day-type within ±21 days. If a factor has no unexposed nights of the matching day type, the comparison is unidentifiable and must return "no signal," not a number.

**Multiplicity at product scale.** 40 factors at α=0.05 gives 2 false discoveries per run; recomputed nightly for a year, ~730 expected false discoveries per user per year. Because consecutive nights' datasets overlap heavily, these surface as a handful of *persistent* false findings that look stable precisely because the data barely changed — and persistence is what a user reads as confirmation.

**The recommended method** is a **stratified permutation test** on paired within-person differences (permuting exposure labels only within day-of-week strata and calendar blocks, since exposure was not randomised), with CIs by test inversion. Validity depends only on the randomisation design, with no distributional assumption, and it stays valid under missing-at-random — which matters because wearable data is full of missing nights. Layer **Bayesian hierarchical shrinkage across the user base** on top: it is the highest-leverage statistical move available, because it pulls noise-driven individual "discoveries" toward zero and makes multiplicity partially self-correcting.

**The language ladder** — what the app is permitted to say, by tier:

| Tier | Conditions | Permitted language |
|---|---|---|
| **0 — no data** | gates fail | "Not enough nights yet. We need 10 with it and 10 comparable without." |
| **1 — no signal** | p ≥ α, or \|d\| < 0.5, or below MDC95 | "We don't see a difference bigger than your normal night-to-night swing." **Never "no effect."** |
| **2 — associated** | ≥6 pairs, p<0.05 uncorrected, d≥0.5, above MDC95, negative control clean | "**tended to be** {Δ, CI} — about {d} of your typical variation. A **pattern in your data, not a proven cause.**" Must show n and CI |
| **3 — reliably associated** | + p < α_FWER, ≥11 pairs, ≥3 weeks, ≥3 alternations, mixed model agrees, held for ≥2 weekly recomputations | "**reliably** {Δ} than matched nights. We matched for day of week. **We still can't rule out something else travelling with it.**" |
| **4 — caused** | + the factor was **actually randomised by the app**, washout enforced, pre-registered | "In a randomized test you ran with the app… For **you**, in **this period**, {practice} **caused** that change." No generalisation |

**Tier 4 is unreachable for alcohol, meals, drinks, sauna and unstructured exercise by construction** — we cannot randomise them. Say so in product copy rather than hiding it. Tier 4 *is* reachable for the things we do control: which breathing practice fires tonight, and when.

**The worked example is sobering.** 90 nights, 14 with alcohol, 11 of them Friday or Saturday. Day-type matching leaves **7** usable pairs. Observed effect −10.9% in ln RMSSD, d=0.64 — but MDC95 = 1.96 × 0.12 × √(2/7) = **12.6%**, so the observed effect sits *below* the instrument's resolution ⇒ **Tier 1, "no signal."** **The true, published, real effect of alcohol on nocturnal HRV sits right at the edge of detectability in 90 nights of one person's data.** Any app confidently asserting it after two weeks is lying.

**Two regulatory notes that bear directly on this** (see §8d for the full treatment). The FTC's 2022 health guidance states that observational studies *"don't prove a causal link"* and that hedges do not rescue a claim — *"it's not enough to say that the product 'may' have the claimed benefit."* **Net impression governs: a chart pairing "drinks" with a dropping HRV line is a claim**, whatever the caption says. And the **July 2025 WHOOP warning letter** turned entirely on language and UX rather than sensors — including **colour-coded green/yellow/orange readings challenged as implying medical interpretation.** That is worth weighing against our existing `IndexBand` vocabulary (act < 45 / improve 45–69 / keep ≥ 70), which is a traffic light in all but name.

**Orthosomnia makes the loss function asymmetric.** Users report that *"sleep tracker data often feels more consistent with their experience of sleep than validated techniques, such as polysomnography."* A false causal sentence is not a neutral error — it is a behavioural intervention. Weight a false positive as far costlier than a false negative.

---

## 8. Apple platform surface and the regulatory line

**Verdict:** the platform is more permissive than expected in the two places that matter commercially — **our server sync is allowed**, and **our ECG-grade RR intervals are genuinely contributable to HealthKit** through a writable beat-level API public since iOS 13. The exposure is not architectural; it is **in the copy and the notification cadence**. Two platform constraints, however, invalidate the obvious overnight design, and one regulatory finding requires changing language already used in this report.

### 8a. HealthKit sleep — what exists

`HKCategoryValueSleepAnalysis` has six live values — `inBed`, `awake`, `asleepCore` (AASM N1+N2), `asleepDeep` (N3), `asleepREM`, `asleepUnspecified` — plus a deprecated `asleep` static var and an `allAsleepValues` set that still contains it. Use `allAsleepValues.contains(_:)` rather than a hand-rolled test, so legacy samples from pre-iOS-16 apps are absorbed.

Apple's documented data model is **two deliberately overlapping layers**: `inBed` intervals as an envelope, and a non-overlapping partition of stage samples inside it. Within one source stages never overlap; **across sources they always do, and Apple ships no reconciliation API.** Reconstruct noon-to-noon (midnight bisects every night), group by `HKSourceRevision.source` before merging anything, and treat stage-coverage gaps as **unknown, not awake** — Apple warns explicitly that Watch samples "might not" cover the beginning or end of an in-bed sample. Write `HKMetadataKeyTimeZone`; without it DST and travel nights corrupt night-boundary logic.

| Identifier | Exists | Third-party write |
|---|---|---|
| `heartRateVariabilitySDNN` | ✅ iOS 11 | ✅ **Yes** |
| `HKHeartbeatSeriesSample` / `HKHeartbeatSeriesBuilder` | ✅ **iOS 13** | ✅ **Yes** |
| `respiratoryRate`, `oxygenSaturation`, `restingHeartRate` | ✅ | ✅ Yes |
| `appleSleepingWristTemperature` | ✅ iOS 16 | ❌ documented read-only |
| `appleSleepingBreathingDisturbances` | ✅ iOS 18 | ⚠️ undocumented — but see §8d, do not write it |
| `HKCategoryTypeIdentifier.sleepApneaEvent` | ✅ iOS 18 | ⚠️ undocumented — **do not write it** |
| `sleepDurationGoal` | ❌ **does not exist** | — |
| `HKUserAnnotatedSleepSchedule` | ❌ **does not exist** | — |

**The find worth acting on: `HKHeartbeatSeriesBuilder`.** It takes beat timings via `addHeartbeatWithTimeInterval(sinceSeriesStartDate:precededByGap:completion:)`, authorized under `HKSeriesType.heartbeat()`. The `precededByGap` flag is exactly the honest encoding for H10 dropouts and filtered ectopics. Our RR is better than the Watch's, and there is a first-class container for it. Verify `maximumCount` against a full night (~28,800 beats at 60 bpm) early — Apple documents the property but not its value.

**`heartRateVariabilitySDNN` is defined over *normal-to-normal* intervals.** Writing raw RR without ectopic filtering makes our SDNN non-comparable with the Watch's and arguably trips App Store 5.1.3(ii) ("must not write false or inaccurate data into HealthKit"). Filter before writing. `HKMetadataKeyAlgorithmVersion` exists for exactly this; set it.

**Three hard negatives.** There is no sleep-goal API of any kind. There is no API for the user's configured bedtime, wake time or wind-down. And **Sleep Focus is undetectable** — `INFocusStatus` exposes only `isFocused: Bool` and cannot distinguish Sleep from Work or Do Not Disturb. The sleep window is **our** onboarding surface, or inferred from H10 wear plus motion. There is also **no API for source priority** — zero `priority` symbols in the framework — so we cannot discover which source the user prefers, and our de-duplication will sometimes disagree with what Health shows them. Budget for that support burden.

### 8b. The two constraints that invalidate the obvious design

**① The HealthKit store is encrypted while the phone is locked.** Apple: *"your app may not be able to read data from the store when it runs in the background… However, your app can still write to the store."* The error is `HKError.errorDatabaseInaccessible`.

**Overnight HealthKit reads fail all night.** Consequences, in order of how badly they bite:
- Guard on `isProtectedDataAvailable` and no-op when locked — **but still call the observer's completion handler.** HealthKit retries with backoff and, after three failures to respond, **stops sending background updates entirely.**
- **Never advance a persisted anchor on a locked-failure path.** This silently skips data and is a documented real-world bug.
- Never coerce a failed read to zero — "encrypted" and "no samples" are indistinguishable at the call site. Only `HKError.errorNoData` means genuinely empty.
- The realistic model is **reconciliation at morning unlock**, not overnight streaming. Buffer H10 data in our own store — which we already do — and settle up with HealthKit when the phone unlocks.

Also: anchored queries **cannot** register for background delivery — only `HKObserverQuery` can, and there is no `HKObserverQueryDescriptor`, so the background path is necessarily the legacy class with a descriptor-based read inside it. Registration must happen synchronously in `didFinishLaunchingWithOptions` on **every** launch, including background launches. Background delivery requires the `com.apple.developer.healthkit.background-delivery` entitlement or `enableBackgroundDelivery` fails with `errorAuthorizationDenied`.

**② CoreBluetooth relaunch has a rule set, and iOS 26 changed it.** [TN3115](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules) (revised 2025-09-15 for iOS 26) is normative. Relaunched: app removed from memory, app crashed, device restarted (**but not until first unlock if a passcode is set**), Control Center Bluetooth toggle. **Not** relaunched: user force-quit, Bluetooth toggled in Settings.

Force-quit is the one that matters — *"user swiped the app away before bed"* is an ordinary Tuesday for a sleep product. **AccessorySetupKit is the only documented way to survive it**, and only from iOS 26. Note this is a capability *gained*, not lost: an Apple engineer states plainly that force-quit apps were **never** relaunchable before, and iOS 26 adds it for ASK adopters.

Relaunch happens *"if and only if"* the app is waiting on a specific Bluetooth event that then occurs. Our design is already on the supported path — the H10 is natively notify-driven, and an outstanding `connect()` **never times out** and **survives termination**, which makes it the single best overnight primitive available. Two entry points must both work: `willRestoreState` fires only when the app was *terminated and relaunched*, not when it is merely woken.

Three specific hazards against our current code:

- **`CBCentralManager` ownership.** DTS prescribes constructing the restore-identified manager in `applicationDidFinishLaunching` as *"the first thing you do."* We construct it inside `AppEnvironment` from `WythinApp.init()`, held as SwiftUI `@State`, while `WythinAppDelegate` exists but is documented as existing "only so notification taps have somewhere to land." The App struct's initializer is not a View body, so this is not the exact failure DTS diagnosed — but the delegate already exists, so moving the manager into it is cheap insurance and matches the prescribed pattern.
- **🔴 The 30-second background tick has no supported mechanism.** `AppEnvironment.swift:733-763` drives a self-timed loop. iOS provides no periodic background timer, and CPU Monitor *"automatically terminates apps that use too many CPU cycles in the background."* **Let the H10's notification stream be the clock.** This is the highest-value change in this section.
- **Scene-based apps get `nil` launchOptions**, so `UIApplicationLaunchOptionsBluetoothCentralsKey` is unavailable — persist the restore identifier ourselves, which `BLEService` already does.

Plan for **many app lifetimes per night** — terminated for memory, relaunched by a BLE event, suspended, terminated again is the normal, DTS-endorsed lifecycle. Persist incrementally as samples arrive; holding eight hours of RR and ACC in memory is precisely what makes us the largest process in a jetsam report. Two open items worth a device test: an **unresolved Apple bug** causes sustained BLE throughput regression on iPhone 17 (~16 KB/s vs ~35–40 on iPhone 16e) — continuous ACC + RR is exactly that workload — and no Apple document states any background memory ceiling or the widely-quoted "10-second BLE callback window." That figure is folklore.

### 8c. Overnight compute, and what the phone can add

**`BGProcessingTask` fits, with caveats.** Apple names this workload directly — *"periods of low activity, such as overnight when the device charges… heavy workloads, such as training machine learning models."* But **"idle" is the normative condition, not charging**; `earliestBeginDate` is a floor and not a schedule; tasks run *"minutes"* and are **terminated the instant the user picks up the device**. So "process last night at 4am" is a request, not a promise: design chunked, resumable, checkpointing work.

Two operational details worth more than the rest of this subsection: setting `requiresExternalPower = true` is *"how you'll disable CPU monitor for CPU intensive tasks"*, and the SwiftData store must be at most `.completeUntilFirstUserAuthentication` file protection or the 4am task launches and immediately fails to open the database. Also add `processing` to `UIBackgroundModes` — a separate checkbox from `bluetooth-central`; we need both. Register each identifier exactly once, in the same `didFinishLaunching` as BLE restoration; the system kills the app on a second registration.

**`CMSensorRecorder` is alive and is the surprise of this section.** Not deprecated, iOS 9+, A10 hardware and above, and Apple DTS calls it *"the 'default' API I suggest for most apps."* It records accelerometer at **50 Hz for up to 12 hours, continuing while the app is suspended or terminated**, retained for three days. Arm it at bedtime, drain on next foreground. Two hazards: `accelerometerData(from:to:)` can throw an **uncatchable `NSException`** if the start date predates the 3-day window — clamp to ~2.9 days or a persisted cursor becomes a launch crash — and the returned list is a lazy XPC iterator, so query in ~10-minute windows.

There is **no `motion` background mode**, and no CoreMotion API wakes a suspended app. The `location`-mode workaround works technically and is a documented **rejection risk** under Guideline 2.5.4. We don't need it: our `bluetooth-central` claim is legitimate, and while the H10 streams we are executing anyway. `CMMotionActivityManager` and `CMPedometer` both retain exactly 7 days of history and are catch-up APIs — useful for a coarse wake bracket and nocturnal bathroom trips. **Do not build the sleep model on the phone.** The H10 is the physiological channel; CoreMotion is cheap corroboration.

**One forward-looking item:** iOS 27 adds a second authorization screen letting users grant only a **recent window** of history, with `getEarliestAuthorizedSampleDate(for:)` to discover it. Apple's instruction — *"Treat all data before that date as unknown, not an absence of data"* and ensure *"trends, baselines, or anomaly detections work from partial data"* — is directly load-bearing for a multi-night baseline product. Design for it now rather than retrofitting.

### 8d. What we may say — and the word we must delete

**FDA reissued the General Wellness guidance on 6 January 2026**, superseding the 2019 version. Any prior compliance thinking is out of date, and the new text is *more* permissive in two ways we can use.

The new section speaks directly to products like ours: FDA may treat non-invasive sensing that infers physiologic parameters — **naming heart rate variability explicitly** — as general wellness, provided the product does not diagnose, does not substitute for an authorized device, does not *"prompt or guide specific clinical action"*, and does **not include values that mimic those used clinically unless validated.** Products meeting those criteria **"may display values, ranges, trends, baselines, or longitudinal summaries, and may contextualize these outputs in relation to sleep, activity, stress, recovery."** That is our §5–6 feature set, authorized verbatim.

There is also a **brand-new safe harbour for the doctor nudge**: a wellness product may notify a user that professional evaluation *"may be helpful when outputs fall outside ranges appropriate for general wellness use"*, provided the notification names no disease, does not characterise the output as *abnormal or pathological*, includes no clinical thresholds, and does not provide *ongoing* alerts intended to manage a condition.

A Polar H10 passes all three limbs of the low-risk test — not invasive, not implanted, no hazardous intervention — cleanly. **Our entire exposure is intended use. This is a copywriting and cadence problem, not an engineering one.** FDA's own Illustrative Example 7 is nearly our product: a wearable assessing activity and recovery where *"sleep is measured via an accelerometer"*, held to be a general wellness claim.

**🔴 The correction this report needs.** DEN180042 and K231173 are both named ***Irregular* Rhythm Notification Feature** — the word "irregular", applied to a physiological rhythm and surfaced as a notification, is literally the name of a Class II device, twice. The January 2026 guidance separately requires that a wellness notification not characterise output as *abnormal*. **The phrasing "your breathing was irregular on N of 7 nights" — used in the brief for this research and echoed in §9 — must not ship.** Replace "irregular" with "less steady" everywhere.

**The Apple precedent is the design template.** Apple built this exact product and drew a line down the middle of it:

| | **Breathing Disturbances** (metric) | **Sleep Apnea Notification** (feature) |
|---|---|---|
| Framing | *"assess restfulness of sleep"* | *"signs of moderate to severe sleep apnea"* |
| Output | ordinal: **elevated / not elevated** | disease-named notification |
| Units | **none** — no index, no events/hour | maps to AHI ≥15 internally |
| Cadence | passive history, user-opened | pushed alert on a 30-day window |
| Status | wellness metric | **Class II, K240929** |

Note that Samsung's cleared feature is a **two-night** assessment and Apple's is **thirty-night** — so multi-night aggregation is *not* what creates a device. **Night count is regulatorily irrelevant.** What created both devices was naming the disease and pushing a risk verdict.

| ❌ Do not ship | ✅ Ships |
|---|---|
| "Sleep Apnea Risk" | **"Breathing Steadiness"** |
| "Breathing Irregularity Index" | **"Overnight Breathing Effort"** |
| "Apnea events" / "Nightly AHI" / anything **per hour** | **"Steady / less steady"** — two-state ordinal, **no units** |
| "Breathing Disturbances" (Apple's cleared term) | "Your breathing was **less steady** on 4 of 7 nights." |
| "4 **abnormal** nights this week" | 7-, 30- and 90-day **trends** against the user's own baseline |
| "We detected signs of sleep apnea." | "Less-steady nights often follow late alcohol, late meals, or back-sleeping." |
| "Consider screening for OSA." | "If you'd like a fuller picture of your sleep, a healthcare provider is a good place to start." |
| **Any auto-fired nightly threshold alert** | User-initiated "share my sleep trends" export |
| "Clinically validated" / "medical grade" | "This is a wellness feature. Not a medical device." |

**The AHI trap is the number, not the word.** We could call it "Breathing Steadiness", never write AHI, and still fail — if the value is a 0–60 scalar with inflection points at 5/15/30. The escape clause permits mimicking clinical values *if validated*, but validating against PSG is precisely the act that proves the intended use is clinical: **you cannot validate your way out of this as a wellness product.** So: ship an **ordinal, not a scalar**; if a continuous value is shown, make it **self-referential** (a percentile against the user's own 30-day baseline); never publish breakpoints at 5/15/30; never express anything per hour; and **do not internally tune a threshold to AHI ≥ 15.** Intended use is evidenced by what was built, not only by what was written, and design-history records are discoverable.

**Two other rules with teeth.** App Store **5.1.3(ii)** bans personal health information in **iCloud** — reinforced by PLA §3.3.3(D), which covers *"create, receive, maintain or transmit"*. No CloudKit, and exclude the local store from iCloud Backup. And **5.1.3(i) reaches our Polar data even though it never touches HealthKit**, because it governs data gathered *"in the health, fitness, and medical research context."* No health values into third-party analytics — the §3.3.3(H) exception cannot be satisfied by an analytics vendor even with consent.

**But the headline is permissive: there is no rule against syncing HealthKit data to a first-party server we operate.** The only storage prohibition is iCloud, and the asymmetry is deliberate — HomeKit's PLA clause *does* forbid off-device transfer, and no equivalent exists for HealthKit. Our server is not a "third party"; it is us. One discipline follows: **HealthKit taint is permanent and travels**, so tag provenance at ingest (`healthkit` / `device_ble` / `derived_from_healthkit`) *before* the two paths merge, or the stricter regime applies to everything.

**EU MDR is less forgiving than FDA, not more.** MDCG 2019-11 was revised (Rev. 1, June 2025) specifically to address devices intended to *"prevent the risk of illness."* Under Annex VIII **Rule 11, software intended to monitor physiological processes is Class IIa on its own — no diagnostic claim required** — and MDCG lists **respiration** as a vital physiological process, so the argument would be IIa versus IIb, not "not a device." Class IIa means a notified body, ISO 13485, and clinical evaluation: a different company, not a bolt-on. A neutral, self-referential steadiness trend framed as sleep quality falls outside MDR as lifestyle software. *"Your breathing was irregular"* asserts that a **vital** parameter departed from normal, and lands at IIa at best.

**The operational rule for both jurisdictions:** write **one** intended-purpose sentence — *"tracking overnight breathing steadiness to help users understand their sleep and recovery"* — and use it **verbatim** in the App Store listing, onboarding, UI, and any technical file. Divergence between those surfaces is the most common way wellness products lose this argument.

### 8e. Unverified — do not rely on without checking

`HKHeartbeatSeriesBuilder.maximumCount`'s actual value; write-ability of `appleSleepingBreathingDisturbances` (Apple ships no documentation at all — test empirically for `errorInvalidArgument`); the value enum behind `sleepApneaEvent`; any sleep-specific `HKUpdateFrequency` cap (Apple's only iOS example is `stepCount`); whether reboot restores background delivery after a force-quit (Apple confirms the covering document was lost in a reorg); and any specific background memory ceiling, GATT notification throttling, or time-based background kill — all community folklore, none of it in Apple's documentation.

---

## 9. Sleep-disordered breathing — what we can honestly claim

Largest opportunity, largest risk, and the evidence points somewhere counter-intuitive.

### Scale

[Benjafield 2019](https://pmc.ncbi.nlm.nih.gov/articles/PMC7007763/): **936 million** adults aged 30–69 with AHI ≥5, **425 million** with AHI ≥15. Treat the precision sceptically — direct data existed for **16 countries from 17 studies**, 177 countries were extrapolated, no African country had any data, and the authors concede possible **48% underestimation / 28% overestimation**. Undiagnosed fraction ([Young 1997](https://pubmed.ncbi.nlm.nih.gov/9406321/)): **82% of men and 93% of women** with moderate-to-severe disease.

### AHI is the wrong target — which is good news for us

The 5/15/30 thresholds came from a **1999 consensus panel with no interventional data**, which admitted in the same document there were *"no data available to indicate an appropriate distinction between mild and moderate."* [Ruehland 2009](https://pubmed.ncbi.nlm.nih.gov/19238801/): median AHI under the ≥4%-desaturation rule is **~30% of** AHI under Chicago criteria, and **~40% of patients positive under one rule are negative under another** — with thresholds unchanged. Re-scoring SHHS liberally moved moderate-severe prevalence **from 22% to 45%**.

Night-to-night instability compounds it. [Lechat 2022](https://pmc.ncbi.nlm.nih.gov/articles/PMC8906484/) — **67,278 people, 11.6 million nights, ~174 nights each** — found mean night-to-night AHI SD of 6 events/h, giving **~21% misclassification from a single night** at AHI ≥15 (~46–48% in the mild-moderate band). F1 rose **0.77 at one night → 0.94 at fourteen**; false positives fell 16.8% → 1.0%.

And the strategic finding: **variability itself predicts outcomes better than severity.** [Lechat 2026](https://pmc.ncbi.nlm.nih.gov/articles/PMC13266556/), n=3,159, mean 109 nights: high night-to-night variability **MACCE OR 1.34 (1.04–1.72)**, while moderate-severe OSA was weaker and non-significant (**OR 1.45, 0.93–2.25**).

**Multi-night home measurement is where a consumer device beats a sleep lab.** That is the argument for the whole feature.

### The metrics that do predict outcomes — one of them is ours

| Metric | Outcome evidence | H10? |
|---|---|---|
| **Hypoxic burden** | CV mortality, MrOS n=2,743 Q5 **HR 2.73**; SHHS n=5,111 Q5 **HR 1.96**. **AHI did not independently predict CV mortality in either** ([Azarbarzin 2019](https://academic.oup.com/eurheartj/article/40/14/1149/5146754)). | **No — needs SpO₂.** |
| **ΔHR — heart-rate response to events** | MESA + SHHS: high vs mid ΔHR ⇒ nonfatal CVD **HR 1.60**, fatal CVD **1.68**, all-cause **1.29**, **independent of AHI** ([Azarbarzin 2021](https://pmc.ncbi.nlm.nih.gov/articles/PMC8483223/)). Treatment-predictive: high ΔHR ⇒ **5.8 mmHg** greater 24-h SBP reduction on CPAP. | **Yes.** |
| **Arousal burden** | Adjusted for AHI: CV mortality **HR 2.17 / 1.60 / 1.35** across SOF, SHHS, MrOS ([Shahrbabaki 2021](https://academic.oup.com/eurheartj/article/42/21/2088/6239256)). Stronger in women. | **Partially** — autonomic, not cortical. |
| **Event duration** | Shortest events ⇒ all-cause mortality **HR 1.31**, adjusted for AHI ([Butler 2019](https://www.atsjournals.org/doi/abs/10.1164/rccm.201804-0758OC)). | Partially. |
| **T90 / ODI** | **HR 1.50** for CV events while **AHI attenuated to non-significance** ([Kendzerska 2014](https://journals.plos.org/plosmedicine/article?id=10.1371/journal.pmed.1001599)). | **No — needs SpO₂.** |

**The pooled CPAP re-analysis closes it.** SAVE, ISAACC and RICCADSA enrolled on AHI and found nothing: ITT **HR 1.01 (0.87–1.17)**. Re-analysed by phenotype (n=3,549), high-risk OSA was defined as **ΔHR > 9.4 bpm *or* hypoxic burden > 87.1 %·min/h**, and benefit concentrated entirely there: high-risk **aHR 0.83** vs low-risk **1.22**, interaction **HR 0.69 (0.50–0.95), p=0.024** ([*Eur Heart J* 2026](https://pmc.ncbi.nlm.nih.gov/articles/PMC12874658/)).

**One of the two components of the best-validated high-risk definition in the field is a heart-rate metric**, computable from ECG at better fidelity than any PPG device, across hundreds of nights. The other component is why SpO₂ is the one sensor worth adding.

### What the market ships, and its real numbers

| Product | Regulatory | Performance |
|---|---|---|
| **Apple** apnea notifications | 510(k) K240929 | AHI ≥15: **sens 66.3%, spec 98.5%**. Reference was a **home test, not in-lab PSG**; sponsor-run. |
| **Samsung** | De Novo DEN230041 | **Sens 82.7%, spec 87.7% — FAILED the prespecified specificity criterion**, rescued post-hoc. **16.7% of nights data-insufficient.** Moderate OSA was the failure mode: 60/91 vs 107/111 severe. |
| **WatchPAT** | Cleared benchmark | Specificity **44% at AHI ≥5**; severity agreement **κ 0.25 for moderate OSA**. Independent pediatric data: **AHI bias +16.9 events/h, severity overestimated in 89%**. |

Both cleared consumer products miss roughly one in five to one in three moderate-to-severe cases by design.

### The autonomic-arousal ceiling

PPG pulse-wave-amplitude drops vs **EEG-scored** arousals: **sensitivity 0.71, specificity 0.59**, and PWAD indices run at **47–52 events/h** because they capture spontaneous, limb-movement and respiratory arousals indiscriminately. **Autonomic arousal is not cortical arousal and must never be labelled as such.**

But the same study found that while event-level agreement was poor, **derived endotypes agreed well**: ICC **0.95 (loop gain)**, 0.85 (arousal threshold), 0.80 (muscle compensation). Aggregate burden over a night is far more trustworthy than any individual event call — the same multi-night logic as Lechat.

### What we can and cannot say

Now verified against primary sources (§8d), and one phrase in the original brief for this research does not survive.

**Can:** report a *personal, multi-night* **breathing-steadiness** and autonomic-disturbance trend against the user's own baseline; report body-position dependence; report night-to-night variability; contextualise it against sleep, recovery, alcohol, late meals and sleep position; and — under FDA's new January 2026 safe harbour — suggest that *"a healthcare provider is a good place to start"* when outputs fall outside the user's usual range.

**Cannot:** report an AHI or anything per hour; call anything "apnea"; produce a severity grade or use 5/15/30 breakpoints; describe a night as *abnormal*; push a recurring nightly threshold alert; or — the specific correction — **call breathing "irregular."** "Irregular Rhythm Notification Feature" is the literal name of a Class II device (DEN180042, K231173). Use **"less steady."**

---

## 10. Migration path — ordered slices, smallest first

Each slice leaves the app coherent. Slices 0–3 use only data already on disk.

0. **De-risk the premise (before writing product code).** Capture 10–15 full nights on a self-applied H10 and measure: overnight IBI completeness and bad-epoch rate; strap-rotation drift in the gravity vector from lights-out to wake; accelerometer noise floor in the 3–25 Hz band; and whether anti-aliasing exists below 100 Hz at the 200 Hz ODR. The published comparators are **49.7% worst-class on a textile belt overnight** and **3× the arm-PPG bad-epoch rate**. If that holds for the H10 it caps every capability in §5 and the roadmap changes shape. No one else has done this measurement.

1. **Fix the silent failures and harden the platform path.** The §4 table — `fetchLimit`, window constants, day-boundary handling, nudge suppression, standby fusion weights. Plus the two §8b items: **replace the self-timed 30 s background tick with the H10's notification stream** (there is no supported periodic background timer, and CPU Monitor terminates background CPU burners), and move `CBCentralManager` construction into `WythinAppDelegate.applicationDidFinishLaunching`. Nothing user-facing; without it every later number is quietly wrong.

2. **Sleep as a fourth `ActivityClass` + regularity.** New `ActivityClass.sleep`, its own window constants and scoring channel, third row/detail branch, backfill bump to v9. Ship **Sleep Regularity Index and duration** first — best evidence-to-effort ratio in the report, needs only onset and wake times, and §7a shows a **fixed wake time beat bright light and melatonin in the only trial that isolated them**. No staging. No stage pie chart.

3. **The night explains the anchor.** Wire nocturnal metrics into the existing morning-anchor narrative (option (c) in §4): HR nadir depth and timing, settling rate after onset, overnight RMSSD trajectory — all from stored `HRVSample`s. Attribution, not alerts.

4. **Coarse three-state segmentation.** `rRR` lag-1 autocorrelation as the SWS detector (87% accurate, near-free), plus the existing coherence channel. Wake / quiet sleep / active sleep, with agreement statistics printed beside it. Report RMSSD and HF *within* detected quiet sleep — where ICC is 0.84 — not as whole-night means.

5. **Nocturnal prognostic metrics.** Surface DC (correct tertiles: >4.5 / 2.6–4.5 / ≤2.5 ms), AC, and PIP/IALS as multi-night trends with breathing-rate control. Add DFA α2 over 50–200 s. These were the only metrics to survive FDR correction in HypnoLaus, and all are already implemented.

6. **The recommendation engine — evidence-gated from day one.** Build the §7f ladder *before* the first rule ships: RR-derived outcomes only (stage-derived quantities are permanently barred from causal attribution), day-type matching, the ≥6-pair resolution floor, stratified permutation testing, and Tier-0/1 language as the default. Then ship the §7a rules in order — regularity, alcohol, exercise ≥4 h before onset, warm bath, evening light, and the 3-hour postprandial HRV mask (internal). Map the surviving breathwork practices to the empty **`PracticeState.sleep`**, framed as wind-down ritual rather than an HRV or deep-sleep claim.

7. **Respiratory effort and body position.** Gravity-vector estimation, project into the orthogonal plane, decimate to 10 Hz. Validate against the existing EDR channel — agreement is the quality gate, divergence is the obstructive signature. Body position ships here as a **continuous roll angle**, not four bins: highest-confidence and most actionable single capability in the report, and structurally impossible on any wrist device.

8. **The OSA risk gate, then the breath-hold inversion.** ECG-HRV OSA risk flag (pooled sensitivity 79%, specificity 75%) as a precondition; then reinterpret stored `HoldProtocol` durations as a loop-gain marker rather than a CO₂-tolerance score (§7b). Hold Breath keeps its practice framing and gains **no** sleep claim. All output subject to §8d: ordinal not scalar, self-referential not clinical, no disease name, no per-hour rate, no nightly pushed alert.

9. **Autonomic event burden and ΔHR.** Per-event heart-rate response and aggregate autonomic disturbance on a personal multi-night baseline — the metric with better outcome evidence than AHI (§9), and half of the only validated high-risk definition in the field.

10. **Contribute back, and publish.** Write RR to HealthKit via `HKHeartbeatSeriesBuilder` with honest `precededByGap` flags, and filtered SDNN with `HKMetadataKeyAlgorithmVersion` (§8a). Then the two literature gaps that fall out of slices 4–5: heart-rate fragmentation and RCMSE stratified by sleep stage — zero prior papers for either.

**Not on the path:** an AHI number, a stage pie chart, a single opaque recovery score, an illness alert, a daily red/amber/green, mouth taping, unsupervised sleep restriction, breath-holding sold as a sleep intervention, or any causal sentence about a single night.

**One naming decision to make before any UI work:** the word **"irregular"** is barred (§8d), and `IndexBand`'s existing act/improve/keep vocabulary is a traffic light in all but name — which is precisely what drew the July 2025 WHOOP warning letter. Settle the vocabulary once, then use it verbatim in the App Store listing, onboarding, UI and any technical file. Divergence across those four surfaces is the most common way wellness products lose this argument.
