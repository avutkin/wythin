# Sleep Tracking — Design-Research Report

**Date:** 2026-08-18
**Scope:** Adding sleep measurement to Wythin. What to measure, how to model a night as an activity, what recovery and sleep-disordered-breathing signals are defensible on Polar H10 hardware, what recommendations can be auto-triggered, and what a chest ECG strap uniquely offers versus the wrist-PPG market.
**Inputs:** full code inventory of the current implementation (`BLE/`, `Metrics/`, `Models/ActivityLog.swift`, `AnchorDetector`, server + MCP surface) plus research reviews on sleep dose–response, OSA epidemiology and the AHI critique, PPG/accelerometer detection performance, ECG-specific staging, overnight autonomic recovery, intervention evidence, and Apple platform APIs. Citations inline.

> **Status:** sections §1–§4 and §9 are complete. §5–§8 are pending the in-flight research tracks (ECG-vs-PPG capability, overnight autonomic recovery, intervention rule set, Apple APIs) and are marked TBD.

---

## 0. The one-paragraph thesis

The sleep-tracking market displays **stage percentages**, which is the metric with the *weakest* outcome evidence and the *worst* measurement accuracy on consumer hardware (4-stage κ ≈ 0.21–0.53). Meanwhile the metrics that actually predict hard outcomes — sleep **regularity**, and for disordered breathing the **heart-rate response to events (ΔHR)** and **arousal burden** rather than AHI — are either free (timing) or computable from beat-to-beat ECG, which is exactly what Wythin already has and what wrist PPG does worst. The strategic move is not to build a worse Oura. It is to ship the two things a chest ECG strap can do better than any ring — **autonomic event response measured over many nights** — and to refuse to display the stage pie chart everyone else leads with.

---

## 1. What we have today — the honest inventory

| Asset | State | Bearing on sleep |
|---|---|---|
| **Polar H10** — single-lead ECG @130 Hz, tri-axial ACC @200 Hz on the sternum, skin-contact bit, battery level (`BLE/PolarH10Profile.swift`) | Production, sole device | Beat-to-beat RR at ECG quality; chest-wall motion; body position available from the gravity vector. **No PPG, no SpO₂, no temperature.** |
| **Background BLE capture** — `UIBackgroundModes: bluetooth-central`, state restoration, 30 s background tick (`AppEnvironment.swift:733-763`) | Working | An 8-hour capture path already exists. Cadence and standby policy need sleep-specific tuning (§4). |
| **`BreathingCompute.swift`** — PCA principal-axis projection of ACC XYZ, Butterworth bandpass, prominence peak detection, I:E phase | Production | This is a **respiratory-effort belt** on a chest-worn device. It is the single most valuable and least appreciated asset for sleep (§5). |
| **`EDRCompute.swift`** — ECG-derived respiration from RR | Production | Second, independent respiratory channel. Effort-vs-EDR divergence is the obstructive-event signature. |
| **`AdvancedHRVCompute.swift`** — deceleration capacity (PRSA, Bauer 2006), RCMSE, HR fragmentation (PIP/IALS) | Production | Prognostically-loaded autonomic metrics, currently only used awake. |
| **`MotionCompute.swift`** — ACC magnitude SD, gravity high-pass, motion-state classification | Production | Actigraphy substrate + body position. |
| **`AnchorDetector`** — still-window detection, stir tolerance, gap ceiling, confidence tiers | Production, **fenced off before 04:00** | Ready-made overnight segmenter. See §4. |
| **`DailyRollup.wearSeconds`**, `HRVSample` → `metric_samples` sync | Production | Storage and sync path is type-agnostic; carries a nightly record with no new infrastructure. |
| HealthKit | **Absent entirely** — no import, no entitlement, no usage strings | Any Apple Watch / phone sleep data is a from-scratch bridge, not a borrow. |
| watchOS target | **Does not exist** | `SDKROOT = iphoneos`, two product types only. |

**What we do not have and cannot get from an H10:** SpO₂ (⇒ no ODI, no oxygen desaturation index, no hypoxic burden), skin temperature (⇒ no distal-proximal circadian proxy, no illness/ovulation signal), airflow, EEG. Every claim in this report is scoped to that constraint.

---

## 2. What sleep science says is worth measuring — ranked by evidence

The commercial instinct is to lead with a stage breakdown. The evidence does not support it. Ranked by strength of the link to real outcomes:

| # | Construct | Evidence | Verdict for Wythin |
|---|---|---|---|
| **1** | **Duration → vigilance / lapses** | Experimental, dose-dependent, large. [Van Dongen 2003](https://academic.oup.com/sleep/article-abstract/26/2/117/2709164): 14 days at 6 h TIB ≈ one night of total deprivation; 4 h ≈ two nights; deficits **do not plateau** (curvature θ≈0.78). Acute TSD meta-analysis [Lim & Dinges 2010](https://www.med.upenn.edu/uep/assets/user-content/documents/LimDinges2010MetaAnalysis.pdf): lapses **g = −0.76 [−0.95, −0.58]**, reasoning essentially spared (−0.13, CI crosses 0). | **Measure and lead with it.** And note the killer product fact below. |
| **2** | **Regularity → mortality, dementia, T2D** | [Windred 2024, *SLEEP*](https://academic.oup.com/sleep/article/47/1/zsad253/7280269), 60,977 UK Biobank, >10 M hours accelerometry: most-regular vs least-regular quintile all-cause **HR 0.70 (0.59–0.83)**, cardiometabolic **0.62**, cancer **0.76**. Head-to-head, AIC favoured SRI over duration (p<0.001), and **adding duration to an SRI model added nothing — LRT χ²(4)=5.94, p=0.20**. Dementia U-shaped, HR 1.53 at the 5th percentile ([*Neurology* 2024](https://europepmc.org/article/MED/38165323)). T2D HR 1.38, **persisting in people sleeping ≥7 h** ([Chaput 2024, *Diabetes Care*](https://europepmc.org/article/MED/39388339)). | **Cheapest high-value metric in the entire report.** Needs only sleep-onset and wake times — no staging, no ECG. Ship it first. Caveat: single cohort (UK Biobank), mean age 62.8, and partly a proxy for shift work / social disadvantage. |
| **3** | **Duration → energy intake** | [Tasali 2022, *JAMA Intern Med*](https://europepmc.org/article/MED/35129580), RCT n=80: +1.2 h/night ⇒ **−270 kcal/d (95% CI −393 to −147)**, measured by doubly-labelled water, not self-report. | Good supporting narrative; not a metric we compute. |
| **4** | **Duration → infection / vaccine response** | [Prather 2015, *SLEEP*](https://academic.oup.com/sleep/article-abstract/38/9/1353/2417971), actigraphy + quarantined rhinovirus challenge: <5 h **OR 4.50 (1.08–18.69)**, 5–6 h **OR 4.24**. Note the CIs. Critically, **actigraphic fragmentation was null (p=0.755)** while duration survived. Vaccine response, [Spiegel 2023 *Curr Biol*](https://europepmc.org/article/MED/36917932): objectively-measured short sleep **ES 0.79 [0.40, 1.18]**, self-reported short sleep **null (0.29, CI crosses 0)**; men 0.93, **women 0.42 (n.s., badly underpowered)**. | Real but imprecise. Usable as context, never as a personal prediction. |
| **5** | **Short duration → mortality** | [Cappuccio 2010](https://pmc.ncbi.nlm.nih.gov/articles/PMC2864873/): RR 1.12 (1.06–1.18), I²=39%. MR-supported ([*Transl Psychiatry* 2024](https://europepmc.org/article/MED/38388528)). | Fine to state. |
| **6** | **Long duration → mortality** | RR 1.30 (1.22–1.38) but **I²=71%**, the signature of confounding; **not MR-supported**; largely absent under accelerometry — [*SLEEP* 2024](https://europepmc.org/article/MED/38995667) found the CVD relationship **L-shaped, not U-shaped**, with >9 h showing no significant association. | **Do not ship.** Never tell a user that sleeping long is harmful. Long sleep is a marker of illness, not a cause of death. |
| **7** | **Sleep → athletic injury** | [Milewski 2014](https://journals.lww.com/pedorthopaedics/fulltext/2014/03000/chronic_lack_of_sleep_is_associated_with_increased.1.aspx): OR 1.7 (1.0–3.0) — **CI touches unity**, and in its own model *school grade* was a stronger, more precise predictor (OR 1.4, 1.2–1.6). Pooled OR 1.34 with **I²=85.6%**, still a preprint. | Weak. Do not build a feature on it. |
| **8** | **Stage percentages → anything** | Observational, confounded by illness and medication, never replicated by intervention. Low REM% → mortality **HR 1.13 per 5%** ([Leary 2020, *JAMA Neurol*](https://europepmc.org/article/MED/32628261)) — but in 76-year-old men, and REM% is depressed by depression, antidepressants, alcohol, OSA and subclinical neurodegeneration, each of which independently predicts death. SWS → dementia **HR 1.27** on **52 events** ([Himali 2023](https://europepmc.org/article/MED/37902739)). The one genuinely experimental stage result is [Tasali 2008 *PNAS*](https://europepmc.org/article/MED/18172212): 3 nights of SWS suppression with TST preserved ⇒ **insulin sensitivity −25%**, n=9. | **Do not headline.** See §3 for the accuracy argument that closes this off entirely. |

### The finding that should shape the product voice

Van Dongen's most product-relevant result is not the dose–response curve. It is the **dissociation**: subjective sleepiness *saturated* (θ=0.24) while objective performance kept degrading linearly, and the 6 h and 4 h arms were **statistically indistinguishable on self-rated sleepiness (F=0.10, p=0.75)** while their measured performance diverged steadily. People chronically restricted to 6 h feel roughly as bad as people at 4 h, and neither can feel how impaired they are.

That is the honest case for measurement, and it is a better one than "optimize your deep sleep." It is also a case Wythin can make without accurate staging.

Second: between-subject SD for the critical wake duration was **3.58 h** (mean 15.84 h, implying sleep need 8.16 ± 0.73 h). Individual sleep need varies enormously, and trait vulnerability to sleep loss is **stable within person and unpredicted by baseline functioning** ([Van Dongen 2004](https://europepmc.org/article/MED/15164894)). Population thresholds are the wrong tool. This is the same conclusion the exercise report reached — personal baselines and SWC bands beat population norms — and it carries over unchanged.

---

## 3. Why we should refuse to show a stage pie chart

Independent 2025 validation, six devices, n=62, simultaneous PSG, no manufacturer funding ([*SLEEP Advances* 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC12038347/)):

| Device | 4-stage Cohen's κ | Wake specificity |
|---|---|---|
| Apple Watch Series 8 | **0.53** | 52.2% |
| Fitbit Sense | 0.42 | — |
| Fitbit Charge 5 | 0.41 | — |
| Whoop 4.0 | 0.37 | — |
| Withings ScanWatch | 0.22 | — |
| Garmin Vivosmart 4 | **0.21** | 29.4% |

Sleep *sensitivity* is 91.7–96.3% across all six — these devices are excellent at noticing you are asleep and near-useless at noticing you are awake. That asymmetry has not moved in over a decade: wake specificity was **33%** in [Marino 2013](https://pubmed.ncbi.nlm.nih.gov/24179309/) (232,849 epochs) and **18–54%** across seven devices in [Chinoy 2021](https://academic.oup.com/sleep/article/44/5/zsaa291/6055610). Garmin's Fenix 5S posted sleep sensitivity 0.99 with specificity 0.18 — it essentially calls everything sleep, and consequently overestimated TST by **+43.7 min** and underestimated WASO by **−49.5 min**.

Pooled summary-metric bias across 24 studies / 798 patients ([JCSM 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC11874098/)): TST **−16.9 min**, efficiency **−4.7%**, WASO **+13.3 min**.

Two further cautions worth internalising before anyone proposes a staging model:

- **Published staging accuracies are inflated by dataset composition.** An "easy-to-classify wake" baseline — simple smoothed activity — explains a large share of reported neural-network AUROC, and models trained without OSA subjects degrade on sleep-disordered cohorts ([*Sleep Adv* 2026](https://pmc.ncbi.nlm.nih.gov/articles/PMC13283449/)).
- **Manufacturer-authored evaluations report better numbers than independent ones.** Samsung's own RNN reports balanced accuracy 71.6%, κ=0.56 ([*Sleep Med* 2024](https://doi.org/10.1016/j.sleep.2024.05.033)); the independent evaluation of Samsung/Withings hardware above lands at κ=0.22. That gap is the flag.

**Verdict.** A stage breakdown at κ≈0.4 is a number precise enough to be believed and wrong often enough to mislead — and §2 established that stage percentages predict nothing robustly anyway. Showing "you got 47 minutes of deep sleep" invites exactly the causal reasoning we cannot support ("my deep sleep was low because I drank"), on a quantity we cannot measure. This is the same call the exercise report made about opaque composite scores, and it should be made the same way: **honest absence over confident fiction.**

If staging ships at all, it ships as a **coarse three-state** read (wake / quiet sleep / active sleep) with the agreement statistics printed next to it, in the app's existing honest-absence idiom. Not a pie chart. Not minutes-of-deep.

---

## 4. Modelling a night — where it fits the codebase and where it breaks

### The verdict: a fourth `ActivityClass`, not a tenth `ActivityType`

Adding `case sleep` to `ActivityType` costs five lines and the compiler will force the `ActivityClass` switch (`Metrics/ActivityClass.swift:53-65`). That is the cheap path and it is wrong, because every window, fetch limit, day-grouping rule and scoring formula in `ActivityLog.swift` assumes a **minutes-long, intra-day, before/during/after-shaped** event.

Reuse: the record, the sync path (type-agnostic), and the server schema (`activity_type` is free-text `TEXT` — **no server migration required**). Fork: the analysis, the window constants, and the UI.

### Silent failures to fix before anything else

These would ship as plausible-looking wrong numbers rather than as errors:

| Defect | Location | Effect on an 8-hour night |
|---|---|---|
| `desc.fetchLimit = 10_000` in `computeHRVWindows` | `ActivityLog.swift:453` | At 2 s ticks this is **5.5 hours**. A night silently truncates. |
| Fixed −300 s / +600 s before/during/after windows | `ActivityLog.swift:443-444` | There is no meaningful 5-minute "before" for sleep (you were awake, upright, possibly eating), and an 8-hour "during" mean flattens the entire architecture of the night — the only thing worth measuring. |
| `computeRecoveryTiming` 4 h horizon, `fetchLimit = 20_000` | `ActivityLog.swift:707,713` | Wrong construct for sleep. |
| `DailyAnchor.day = startOfDay(startedAt)` | `DailyAnchor.swift:9` | A 23:00–07:00 span cannot be represented; the night lands on the previous date. |
| `ActivitiesView.dayGroups` groups on `startOfDay(startedAt)` | `ActivitiesView.swift:44` | Same, in the UI. Server buckets by **UTC** day (`mcp_server.py:201-203`), a known documented discrepancy. |
| `activityInProgress = true` for the whole night | `NudgeEngine.swift:83` | **Mutes the entire nudge engine overnight** and calls `durations.interrupt()`. |
| Off-body standby fuser scores dead-still ACC as **+1 toward off-body**; `contact == true` only −1 | `AppEnvironment.swift:783-817` | A motionless sleeper accumulates toward standby. Overnight capture fights the power-saving logic. Needs a sleep-context re-weighting. |
| Picker grid sized "exactly three rows" | `ActivityFormSheets.swift:326-330` | 9 tiles + Sleep = 10 breaks the layout. |
| `currentVersion = 8` backfill counter | `ActivityLog.swift:417` | Any new stored field is **invisible on existing rows** unless bumped to 9. |

### The anchor collision — the real design decision

`AnchorThresholds.earliestAnchorHour = 4` exists *specifically* to keep sleep out of the morning anchor, and the comment (`AnchorDetector.swift:35-44`) states why: *"Sleep is the stillest, cleanest signal there is, so an overnight stretch outscores every waking rest and would be labelled the morning read — and a history mixing hour≈1 and hour≈7 anchors fails `PotentialScore`'s hour-tolerance check."*

This is correct and should not be relaxed. But it is also an admission that **the best signal the app ever collects is currently discarded.** Three options:

- **(a) Sleep replaces the anchor.** Rejected — breaks `PotentialScore`'s hour tolerance (`maxHourDeviation = 4`) and `AnchorBaseline.hourTolerance = 2 h`, and destroys 60 days of baseline comparability.
- **(b) Sleep and anchor stay fully disjoint.** Safe, and wastes the asset.
- **(c) Sleep *explains* the anchor — recommended.** The night produces its own metrics on its own baseline; the morning anchor stays exactly as it is; the night is what the anchor is *attributed to*. "Your morning RMSSD is 18% below your usual — the night before showed a late HR nadir and elevated resting HR from 01:00." This preserves every existing invariant, needs no threshold change, and is the more useful product besides.

The anchor detector's machinery (still-window runs, `maxStirSec = 45`, `maxGapCeilingSec = 120`, confidence tiers) is directly reusable as an overnight segmenter under a **separate threshold set** — same code, sleep-specific constants.

### `PracticeState.sleep` already exists

The practice catalog has an "Improve Sleep" goal with **zero practices mapped to it** (`PracticeCatalogTests.swift:93` — "anxiety and sleep are empty for now"). That is a pre-built hook for the recommendation layer in §7.

---

## 5. What a chest ECG strap uniquely offers versus PPG — TBD

*Pending research track. Will cover: ECG-vs-PPG staging from RR intervals; stage-specific behaviour of the metrics already computed (DFA-α1, DC, RCMSE, PIP/IALS, RSA, cardiopulmonary coherence); chest-accelerometer respiratory effort and obstructive-vs-central discrimination; body position from the sternum gravity vector; nocturnal AF and CVHR; and the honest counter-case (no SpO₂, no temperature, comfort, trunk-vs-wrist actigraphy).*

---

## 6. Overnight autonomic recovery — TBD

*Pending research track. Will cover: normal overnight HRV trajectory; HR nadir depth and timing as a recovery marker; settling rate after sleep onset; the alcohol / late-meal / late-exercise autonomic signatures; respiratory rate as illness early-warning; and whether whole-night measurement beats the existing morning anchor.*

---

## 7. Recommendations that can be auto-triggered — TBD

*Pending research track. Will deliver an evidence-graded rule table: trigger metric → recommendation → confirmation metric → evidence grade, plus the n-of-1 causal-inference discipline and the orthosomnia guardrails.*

---

## 8. Apple platform surface — TBD

*Pending research track. HealthKit sleep identifiers, background delivery, overnight BLE limits, `BGProcessingTask`, App Store and wellness-regulatory posture.*

---

## 9. Sleep-disordered breathing — what we can honestly claim

This is the section with the largest opportunity and the largest risk, and the evidence points somewhere counter-intuitive.

### The scale of the problem

[Benjafield 2019, *Lancet Respir Med*](https://pmc.ncbi.nlm.nih.gov/articles/PMC7007763/): **936 million** adults aged 30–69 with AHI ≥5 worldwide, **425 million** with AHI ≥15. Treat the precision sceptically — direct prevalence data existed for only **16 countries from 17 studies**, 177 countries were extrapolated, no African country had any data, and the authors concede possible **48% underestimation / 28% overestimation**.

Undiagnosed fraction, the canonical source ([Young 1997, *Sleep*](https://pubmed.ncbi.nlm.nih.gov/9406321/)): **82% of men and 93% of women** with moderate-to-severe sleep apnea syndrome were clinically undiagnosed, in an employed population without obvious barriers to care.

### AHI is the wrong target — and that is good news for us

The severity thresholds (5/15/30) came from a **1999 AASM consensus panel with no interventional data**, which stated in the same document that *"there are no data available to indicate an appropriate distinction between mild and moderate degrees of obstructed breathing events"* ([review](https://pmc.ncbi.nlm.nih.gov/articles/PMC4835315/)).

The hypopnea-definition problem is decisive: [Ruehland 2009](https://pubmed.ncbi.nlm.nih.gov/19238801/) found median AHI under the ≥4%-desaturation rule was **~30% of** AHI under Chicago criteria, and **~40% of patients positive under one rule become negative under another** — with the 5/15/30 cutpoints left unchanged. Re-scoring SHHS with liberal criteria moved moderate-severe prevalence **from 22% to 45%**. AHI is not a stable quantity.

Night-to-night instability compounds it. [Lechat 2022, *AJRCCM*](https://pmc.ncbi.nlm.nih.gov/articles/PMC8906484/) — **67,278 people, 11.6 million nights, ~174 nights each** — found mean night-to-night AHI SD of 6 events/h (rising to 14 in severe OSA), giving **~21% misclassification from a single night** at the AHI ≥15 threshold (~46–48% in the mild-moderate band). F1 rose from **0.77 at one night to 0.94 at fourteen**; false positives fell from 16.8% to 1.0%.

And the follow-up is the strategic finding: **night-to-night variability itself predicts outcomes better than severity does.** [Lechat 2026, *Sleep*](https://pmc.ncbi.nlm.nih.gov/articles/PMC13266556/), n=3,159, mean 109 nights: high variability (75th vs 25th percentile) carried **MACCE OR 1.34 (1.04–1.72)**, while moderate-severe OSA itself was weaker and non-significant (**OR 1.45, 0.93–2.25**).

### The metrics that do predict outcomes — and one of them is ours

Adjusted for AHI, or outperforming it outright:

| Metric | Outcome evidence | Can H10 measure it? |
|---|---|---|
| **Hypoxic burden** (area under the desaturation curve) | CV mortality, MrOS n=2,743: Q5 **HR 2.73 (1.71–4.36)**; SHHS n=5,111: Q5 **HR 1.96 (1.11–3.43)**. **AHI did not independently predict CV mortality in either.** ([Azarbarzin 2019, *Eur Heart J*](https://academic.oup.com/eurheartj/article/40/14/1149/5146754)) | **No — needs SpO₂.** The single strongest argument for adding an oximeter. |
| **ΔHR — the heart-rate response to events** | MESA n=1,395 + SHHS n=4,575: high vs mid ΔHR ⇒ nonfatal CVD **HR 1.60 (1.28–2.00)**, fatal CVD **1.68 (1.22–2.30)**, all-cause mortality **1.29 (1.07–1.55)**, **independent of AHI** ([Azarbarzin 2021, *AJRCCM*](https://pmc.ncbi.nlm.nih.gov/articles/PMC8483223/)). Also *treatment-predictive*: in HeartBEAT, high ΔHR predicted **5.8 mmHg (1.0–10.6)** greater 24-h SBP reduction on CPAP ([*Hypertension* 2024](https://pmc.ncbi.nlm.nih.gov/articles/PMC11056868/)). | **Yes — this is a beat-to-beat interval measurement.** See below. |
| **Arousal burden** (cumulative arousal duration / TST) | MrOS + SOF + SHHS, all adjusted for AHI: CV mortality **HR 2.17 (1.04–4.50)** SOF women, **1.60 (1.12–2.28)** SHHS women, **1.35 (1.02–1.79)** MrOS men ([Shahrbabaki 2021, *Eur Heart J*](https://academic.oup.com/eurheartj/article/42/21/2088/6239256)). Stronger in women — the reverse of the AHI literature. | **Partially** — autonomic arousal from RR, not cortical arousal. Accuracy ceiling discussed below. |
| **Event duration** (short events = low arousal threshold / high loop gain) | SHHS n=5,712, 1,290 deaths: shortest-duration events ⇒ all-cause mortality **HR 1.31 (1.11–1.54)**, adjusted for AHI ([Butler 2019, *AJRCCM*](https://www.atsjournals.org/doi/abs/10.1164/rccm.201804-0758OC)) | Partially, via the autonomic signature. |
| **T90 / ODI** | Kendzerska 2014, n=10,149: TST90 **HR 1.50 (1.25–1.79)** for CV events while **AHI attenuated to non-significance (p>0.2)** ([*PLoS Med*](https://journals.plos.org/plosmedicine/article?id=10.1371/journal.pmed.1001599)) | **No — needs SpO₂.** |

**The pooled CPAP re-analysis closes the argument.** The three big negative CPAP trials (SAVE, ISAACC, RICCADSA) enrolled on AHI and found nothing: intention-to-treat **HR 1.01 (0.87–1.17)** ([*JAMA* 2023](https://pmc.ncbi.nlm.nih.gov/articles/PMC10548300/)). Re-analysed by risk phenotype across all three (n=3,549), high-risk OSA was defined as **ΔHR > 9.4 bpm *or* hypoxic burden > 87.1 %·min/h** — and CPAP benefit concentrated entirely there: high-risk **aHR 0.83** vs low-risk **1.22**, interaction **HR 0.69 (0.50–0.95), p=0.024** ([*Eur Heart J* 2026](https://pmc.ncbi.nlm.nih.gov/articles/PMC12874658/)).

**One of the two components of the best-validated high-risk definition in the field is a heart-rate metric.** Wythin can compute ΔHR from ECG at better fidelity than any PPG device, over hundreds of nights rather than one. That is the differentiated position, and it rests on stronger evidence than the AHI-based screening every consumer device is chasing.

### What the market actually ships, and its real numbers

| Product | Regulatory | Performance |
|---|---|---|
| **Apple** sleep apnea notifications | 510(k) **K240929**, cleared 2024-09-13 | AHI ≥15: **sensitivity 66.3% (62.2–70.3), specificity 98.5% (98.0–99.0)**. Reference standard was a **Nox T3s home test, not in-lab PSG**; sponsor-run. |
| **Samsung** sleep apnea feature | De Novo **DEN230041**, granted 2024-02-06 | **Sensitivity 82.7%, specificity 87.7% — which FAILED the prespecified specificity criterion**, rescued to 91.1% only by post-hoc reclassification. Data-insufficiency rate **16.7% of nights**. Moderate OSA was the failure mode: **60/91** detected vs 107/111 severe. |
| **WatchPAT** (the validated benchmark) | Cleared | Specificity **44% at AHI ≥5**, 74% at ≥15 ([Ichikawa 2022](https://doi.org/10.1111/jsr.13682), 13 studies, n=1,227). Severity-agreement **κ = 0.25 for moderate OSA** ([JCSM 2022](https://jcsm.aasm.org/doi/10.5664/jcsm.9808)). Independent pediatric data: **AHI bias +16.9 events/h, severity overestimated in 89%** ([JCSM 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC11965089/)). |

Both cleared consumer products **miss roughly one in five to one in three moderate-to-severe cases by design**, and both trade sensitivity against specificity in opposite directions.

### The autonomic-arousal accuracy ceiling — know it before designing

PPG pulse-wave-amplitude drops against **EEG-scored** arousals: **sensitivity 0.71, specificity 0.59** ([*Chest* 2026](https://pmc.ncbi.nlm.nih.gov/articles/PMC13197968/)). And PWAD indices run at **47–52 events/h** in general populations — an order of magnitude above scored respiratory-arousal rates — because they capture spontaneous, limb-movement and respiratory arousals indiscriminately ([*AJRCCM* 2023](https://pmc.ncbi.nlm.nih.gov/articles/PMC10273112/)).

Autonomic arousal is **not** cortical arousal and must never be labelled as such. But note the same *Chest* study found that while event-level agreement was poor, the **derived endotypes agreed well**: ICC **0.95 (loop gain)**, 0.85 (arousal threshold), 0.80 (muscle compensation). Aggregate autonomic burden over a night is far more trustworthy than any individual event call — which is the same multi-night logic as Lechat.

### What we can and cannot say

**Can:** report a *personal, multi-night* autonomic-disturbance burden with its own baseline; report body-position dependence; report night-to-night variability (which has independent outcome evidence); recommend a clinical conversation when a sustained pattern crosses a conservative, multi-night threshold.

**Cannot:** report an AHI, call anything "apnea," produce a severity grade, or imply diagnosis. The specific regulatory language is pending §8.

---

## 10. Migration path — TBD

*Ordered, individually-shippable slices, in the style of the exercise report §5. Pending §5–§8.*
