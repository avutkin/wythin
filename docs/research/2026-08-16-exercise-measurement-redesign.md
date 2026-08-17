# Exercise Measurement Redesign — Design-Research Report

**Date:** 2026-08-16
**Scope:** Wythin iOS exercise-session measurement (Polar H10, HR + HRV only). Restructure top-down: few key metrics on top, insightful detail below, defensible long-term impact, correct handling of yoga/mind-body sessions.
**Inputs:** full code inventory of the current implementation (`Metrics/`, `Models/ActivityLog.swift`, `ExerciseLogRow`, `ExerciseQuestionSections`) plus three research reviews: acute-session metrics, long-term monitoring, and mind-body sessions. Citations inline.

---

## 1. What we measure today — verdict per metric

| Metric (code) | What it is | Verdict | Why |
|---|---|---|---|
| **Overall score** (`ExerciseOverallScore`: recovery .45 / suppression .35 / efficiency .20) | Weighted composite over present axes, crown at ≥85 | **DROP as headline** | Opaque composites are the one thing the literature explicitly condemns: none of 14 consumer composite scores survived independent validation ([De Gruyter 2025](https://www.degruyterbrill.com/document/doi/10.1515/teb-2025-0001/html?lang=en)). Two of its three inputs (VSI slope, DC-vs-motion slope) are house-invented with no external validation, so the composite inherits their uncertainty at 55% weight. Replace with three transparent top-line numbers (§2). The design instinct that produced it — *Load never enters, "the crown would go to whoever went hardest"* — is correct and carries over. |
| **Readiness** (`ReadinessScore`: percentile of beforeRMSSD/beforeHR/beforeDC vs own pre-session windows) | 0–100 vs last ≤60 activating sessions | **KEEP — reposition** | Transparent inputs, individual baseline, unweighted mean — exactly the anti-black-box design the research asks for. Crucially it already does **not** enter the session score, which matches the evidence-based rule "contextualize, don't gate": readiness has RCT support only as a *prospective* prescription signal (Kiviniemi 2007; [Javaloyes 2019]; [meta-analysis](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC7663087/)), and retrospective rescoring of sessions by same-morning readiness has no evidence base and injects ~10% day-to-day CV noise. Move it out of the session card into a "context" line and a *pre-session* surface. |
| **Load** (`ExerciseIntensity.load`: Banister TRIMP, 1.8 exponent) | Σ x·e^(1.8x)·dt, personal reserve span | **KEEP — promote to top line** | Banister TRIMP is the defensible strap-only default (r ≈ 0.79–0.86 vs sRPE; [review](https://pmc.ncbi.nlm.nih.gov/articles/PMC5673663/)). Current code already refuses to fold it into the quality score and already treats units as personal-only — both match best practice. Two upgrades: band it against the user's own rolling distribution ("142 — high for you", the Polar Training-Load-Pro pattern, the best load UX in the market survey), and later individualize the curve with DFA-a1-derived HRVT1/HRVT2 ([2025 internal-exposure construct](https://pmc.ncbi.nlm.nih.gov/articles/PMC12528351/)). Known structural limit: underestimates strength/interval work ([karate finding](https://pubmed.ncbi.nlm.nih.gov/36247939/)) — add an sRPE cross-check prompt for those subtypes. |
| **HRR60** (`HeartRateRecovery`: interpolated HR@60s, ending-intensity gate, anchored 10–40 bpm) | HR drop in first minute post-stop | **KEEP — promote to top line** | The single best-validated per-session metric available: ICC up to 0.99, CV ~3.4%, deep prognostic literature ([reproducibility review](https://www.sciencedirect.com/science/article/abs/pii/S1566070219300463); [JAHA 2024](https://www.ahajournals.org/doi/10.1161/JAHA.124.039792)). The existing ending-intensity gate (≥30% of reserve at stop) is exactly the "only score HRR when a clean stop at meaningful intensity exists" rule the research demands — say so, keep it. Missing piece: normalize/compare against the user's own HRR at similar end-intensity before trending (an easy session has intrinsically less to recover from). |
| **T30** (stored `t30Seconds`, never surfaced) | Semilog time constant, first 30 s | **KEEP HIDDEN — current behavior is correct** | Purest parasympathetic-reactivation index pharmacologically, but field reliability is dismal (ICC as low as 0.12, CV up to ~90%; same review). No product surfaces it. Continue storing it silently; at most use it to stabilize the recovery-curve fit. Do not churn. |
| **HR zones** (`HeartRateZones`: 5 floors on %HRR) + **DFA-a1 domains** (0.75/0.50) | Time-in-zone / time-in-domain | **KEEP — promote; add artifact gate** | Both match validated practice: %HRR zones are the STRONG-but-crude workhorse; a1 = 0.75/0.50 thresholds are validated against gas exchange and lactate ([Rogers 2021](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC7845545/); [VT2](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8167649/); [2024 reliability](https://www.tandfonline.com/doi/full/10.1080/02640414.2024.2421691)). The code's deliberate zones-vs-domains distinction ("disagreement is signal") is *explicitly endorsed* by the literature — a1 drifting down at constant HR is a validated durability/fatigue marker ([EJSS 2024](https://onlinelibrary.wiley.com/doi/full/10.1002/ejsc.12175); [Gronwald/Rogers 2022](https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2022.879071/full)). Missing and mandatory: an artifact-rate gate — ~2–3% missed beats bias a1 upward enough to misplace the zone-1 boundary ([H10 vs ECG](http://www.muscleoxygentraining.com/2021/03/dfa-a1-agreement-using-polar-h10-ecg.html)). Suppress a1 outputs above ~5% artifacts; badge the rate. |
| **Brake release / Suppression** (`brakePerBeat` ms/bpm; `vsiSlopePer10` = ln DC vs %HRR) | Vagal-withdrawal cost of the HR rise | **DEMOTE to detail; rename** | Physiology is blockade-verified STRONG, but as a per-session comparison metric during-work vagal indices are MODERATE at best, with floor/ceiling effects and HR-dependence ([blockade](https://journals.physiology.org/doi/full/10.1152/japplphysiol.00619.2018)). DC-vs-%HRR slope is a house invention — reasonable, but no external validation; it must not sit near the top of the hierarchy. The inventory's own limitation stands: window-average `brakePerBeat` cannot tell an interval session from an even one. Keep as a detail-level "autonomic cost" tile; fold the refined story into the a1 timeline (the research's preferred within-work autonomic index precisely because it keeps dynamic range at all intensities). The `vagalRoseDuring` flag is a gem — see §4. |
| **Efficiency** (DC vs motion slope + `hasExternalWorkSignal` gate) | Vagal cost per unit external work | **DEMOTE to detail; fix the blank-start** | Chest motion as work proxy is invalid for lifting/cycling/swimming — the code already knows this and gates by subtype (keep, correct). But the metric is doubly unvalidated (invented slope × crude work proxy) and its percentile score is blank until 3 same-group peers while sibling axes were converted to anchored scores. Either anchor it like Suppression or accept it as an exploratory detail row. Never promote. Real efficiency lives in §3 as the HR:pace/decoupling *trend* once an external work signal (pace/power) exists. |
| **Bounce-back** (mean of HRR60-score, half-recovery-score, dead decoupling term) | Composite recovery index | **SPLIT** | Mixing an ICC-0.99 metric (HRR60) with a moderate one (DC half-recovery) and a permanently-nil third term (decoupling hardwired count 0) dilutes the best number we own. Lead with HRR60 alone; show half-recovery time as the second-level recovery-timeline detail; delete the dead decoupling input (it belongs to the long-term trend, §3, not to a single session). |
| **Recovery timing** (`RecoveryTiming`: DC halfway-back, 4 h horizon, `.notReached` scores 0) | Vagal-reactivation kinetics | **KEEP — detail level** | Post-exercise vagal-reactivation kinetics are physiologically grounded (Stanley/Buchheit, [Sports Med 2013](https://link.springer.com/article/10.1007/s40279-013-0083-4)); windows ≥2 min post-exercise are reliable. "notReached = 0, information not missing value" is good design. Belongs in the recovery story, not the headline. |
| **Warm-up speed / Mobilisation** (defined, no stored input, never renders) | HR on-kinetics analog | **KEEP DORMANT** | Real fitness signal (trained t½ ~24 s vs untrained ~47 s) but MODERATE evidence and fragile in free-living use: needs a ≥2–3 min quasi-constant onset the strap can't verify ([kinetics](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC4687158/)). The current honest absence ("not stored yet, absent rather than estimated") is the right posture. Ship only after series storage (slice 7), gated on a detected steady onset, detail-only. |
| **Steadiness / drift** (defined, unused) | Within-session HR drift | **REPURPOSE for long-term** | Within-session decoupling is defensible — but as a *longitudinal* fitness/durability marker on matched steady sessions ([TrainingPeaks Pa:Hr](https://www.trainingpeaks.com/coach-blog/aerobic-endurance-and-decoupling/); [durability](https://www.researchgate.net/publication/351064181_The_Importance_of_'Durability'_in_the_Physiological_Profiling_of_Endurance_Athletes)), confounded session-to-session by heat/hydration/caffeine. Don't render it as a per-session verdict; feed it to the §3 trend. The a1-vs-HR divergence covers the per-session drift story. |
| **Peak HR / DC trough** (90th/10th pct) | Ungraded doses | **KEEP** | Artifact-resistant percentile extremes, correctly ungraded. No change. |
| **Classification** (`measuredClass` returns label; measured-rise machinery is dead code) | activating vs restorative | **FIX — measure, don't just label** | See §4. The stale v7 backfill comment ("now follows measured heart-rate rise") documents an intent the code never shipped. |
| **Crown/laurel gating** (string-keyed on "alone so far"; row uses 50, crown 85) | Award logic | **DROP with the composite** | Dies with the overall score. If any award survives, key it off a typed enum, not caption vocabulary. |
| **reactivationScore** (afterDC/preDC %, "1 of 7") | Legacy recovery path | **DROP** | Superseded by RecoveryTiming; dead weight. |
| **Recommendation card** (deterministic weakest-index advice) | One next-step sentence | **KEEP — rewire** | Deterministic, transparent, actionable — fine. Re-point its inputs at the new hierarchy (it currently references never-rendering indices like Warm-up speed and Steadiness). |

**Bottom line:** the plumbing is largely right — TRIMP, HRR60, zones+domains, quality gates, honest-absence design, load-outside-the-score, readiness-outside-the-score all match best practice and should be said out loud, not rebuilt. What's wrong is the *hierarchy*: the two least-validated inventions (VSI slope, motion-efficiency) hold 55% of the headline while the two best-validated numbers we already store (Load, HRR60) sit below the fold as an ungraded dose and a buried sub-score.

---

## 2. Proposed top-down hierarchy

Market pattern (Garmin, Whoop, Polar, HRV4Training): **one load number banded against personal norms + a plain-language sentence; everything else one tap down.** Nobody surfaces T30, tau, or raw during-work RMSSD top-line. We follow that, with three numbers instead of one composite.

### TOP LINE — max 3 numbers, consumer-named, all from stored fields

| # | Name | Value | Source | Banding |
|---|---|---|---|---|
| 1 | **Effort** | Load, banded vs own last-90-day distribution: "142 — high for you" | `exerciseLoad` (stored) | Personal quantile bands (new computation, no schema change) |
| 2 | **Intensity** | Dominant-domain verdict + mini 3-zone bar: "mostly moderate" | `domainModerateSec/HeavySec/SevereSec` + `zone1–5Sec` (stored) | a1 verdict suppressed when artifact-gated (new `artifactPct` field) |
| 3 | **Recovery** | HRR60 vs own baseline at similar end-intensity: "34 bpm — typical for you" | `hrr60Bpm` (stored) + `duringHRPeak`/`beforeHR` for end-intensity matching | Personal baseline; literature bands (≤12 flagged / 20–30 healthy / 30–50 trained) as secondary context — already quoted in the detail screen today |

Plus **one generated sentence** combining the three ("A high-load, mostly-moderate session; recovery on par with your usual"). No composite 0–100, no crown.

Readiness appears as a one-line *context annotation* under the top line ("started on a low-readiness morning"), never as a scoring input — the evidence for readiness is prospective, not retrospective (§1, §3).

### SECOND LEVEL — the session story (four short blocks, replacing the five question cards)

1. **How hard, really** — 5-zone table + a1-domain split side by side; when they diverge, say it: "HR said easy, your autonomics said heavy — the session got internally harder as it went" (validated drift/durability reading, [EJSS 2024](https://onlinelibrary.wiley.com/doi/full/10.1002/ejsc.12175)). Sources: stored zone/domain seconds; divergence needs the a1 timeline (new series field, slice 7; until then, domain-vs-zone share comparison from stored seconds is an honest first cut).
2. **What it cost** — autonomic cost tile (`brakePerBeat` ms/beat, renamed plainly), DC trough, Load-vs-cost kept uncombined (current rule, correct). Suppression verdict wording stays cost-vocabulary ("cheap … costly"), which is good design — keep.
3. **How you came back** — recovery timeline: HRR60, half-recovery minutes (`halfRecoveryMinutes`), brake at 10 min (`afterTailDC`); ΔRMSSD pre→post where the after-window is spontaneous breathing. T30 stays invisible.
4. **What to do next** — the recommendation card, re-pointed at the new axes.

### DETAIL — charts and raw (tap-through)

- Full HR trace with zone shading; per-zone TRIMP contribution (computable from stored samples at view time until series storage lands).
- DFA-a1 timeline with HRVT1/HRVT2 lines and **artifact-rate badge** — requires new fields: downsampled in-session series (`sessionSeriesBlob`, slice 7) and `artifactPct` (slice 4).
- Recovery curve with exponential fit (T30 used silently to stabilize the fit).
- Onset kinetics (warm-up tau) — only when a ≥2–3 min quasi-steady onset is detected; otherwise absent, in the app's existing honest-absence style.
- Window-average table (already stored: before/during/after × 11 metrics).

**Gating rules (verbatim from the research):** suppress a1 above ~5% artifacts; suppress HRR60 without a clean detected stop (the existing ending-intensity gate, plus an HR-inflection/motion stop check); suppress tau without a valid onset; never compare during-work RMSSD to resting RMSSD.

### New fields required (all optional, SwiftData-migratable like the v8 set)

| Field | For | Slice |
|---|---|---|
| `artifactPct` (per window or session) | a1 gating, badge | 4 |
| `driftPercent` (steady-segment HR drift) | §3 decoupling trend | 6 |
| `sessionSeriesBlob` (downsampled HR/RR/motion/a1) | a1 timeline, tau, per-zone TRIMP, interval-aware cost | 7 |
| `sRPE` (user-entered, optional prompt) | strength/mind-body load cross-check | 5 |
| `breathRateDuring` / `minutesSlowBreathing` | mind-body dose (§4) | 5 |
| `postureTransitionsPerMin` (from motion) | mind-body classifier (§4) | 5 |

---

## 3. Long-term impact — what is defensible

"Impact" language belongs to multi-week trends, not single sessions: **training adaptation is only visible at the weeks scale; single-session "fitness gained" numbers are fiction.** Session scores are load/stimulus; impact is trend. Ranked by evidence strength:

| Trend | Window | Display | Science |
|---|---|---|---|
| **1. Resting HRV baseline** | 7-day rolling ln RMSSD vs individual SWC band (±0.5 × CV of baseline), 60-day context | Line + band + state label: *in band / suppressed / unusually elevated*. Elevated is **not** automatically good — vagal HRV rises with both adaptation and functional overreaching ([Bellenger 2016](https://www.researchgate.net/publication/295077961); [2021](https://onlinelibrary.wiley.com/doi/10.1111/sms.13932)); read jointly with load (Buchheit 2014). Secondary flag: collapsing day-to-day CV = early overreaching warning ([Flatt/Plews](https://www.frontiersin.org/journals/physiology/articles/10.3389/fphys.2015.00343/full)). Single-day readings are noise (CV ~10–12%) — never headline one. | Strongest evidence base in this space: HRV-guided training RCTs and meta-analyses all key off exactly this construct ([Granero-Gallegos 2020](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC7663087/); [Manresa-Rocamora 2021](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8507742/)). Data already exists in DailyAnchor. |
| **2. Resting HR** | Same rolling-mean-vs-SWC treatment | Months-scale downward drift at stable load = aerobic adaptation; acute jump = fatigue/illness | Cheapest, most robust single metric. |
| **3. Aerobic efficiency / decoupling** | Monthly, on **matched** steady sessions only (similar duration/intensity/conditions) | "Fitness & durability" trend line | Genuinely session-derived, attenuates with training, predicts endurance performance ([TrainingPeaks](https://www.trainingpeaks.com/coach-blog/aerobic-endurance-and-decoupling/); [Frontiers 2025](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12271085/)); "durability" is now a formalized fourth determinant of endurance performance ([JAP](https://journals.physiology.org/doi/full/10.1152/japplphysiol.00671.2025)). This is where the dormant Steadiness index goes. Matched-session filter is non-negotiable (heat/hydration/caffeine confounds). |
| **4. Recovery-speed** | HRR60 at matched end-intensity, trended across months; plus time-to-baseline of ln RMSSD/RHR after hard sessions (48–72 h rebound) | "Your bounce-back is getting faster" — labeled **exploratory** | Vagal-reactivation kinetics track fitness; as a trend product less directly validated — present honestly. |
| **5. Load structure** | Acute EWMA (τ≈7 d) and chronic EWMA (τ≈28–42 d) as **two separate lines**, never a ratio; Foster weekly monotony/strain as descriptive hygiene | "Load is high AND monotonous — vary your days" | EWMA > rolling ACWR ([Murray 2017](https://pubmed.ncbi.nlm.nih.gov/28003238/)); Foster 1998 descriptive, uncontroversial. |

**Do not ship:** ACWR sweet-spot gauges or any injury-risk % — mathematically coupled ratio, discredited ([Impellizzeri 2020](https://journals.humankinetics.com/view/journals/ijspp/15/6/article-p907.xml); [Bayesian re-analysis](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC9572878/)). Black-box composite readiness. Retroactive session rescoring by morning readiness. Per-session "fitness gained" points.

**Where readiness earns its keep long-term:** the RCT-validated pattern is prospective — 7-day ln RMSSD below the SWC band → recommend an easy day. Wythin's readiness score can evolve into exactly that (it already uses personal baselines); the legitimate retrospective uses are annotation ("hard session on a low-readiness day") and pattern flags (repeated hard sessions during a suppressed week; baseline not rebounding within 48–72 h).

**Design principle across all of it:** individual baselines + rolling averages + SWC bands beat population thresholds; always show the raw trend behind any label — transparency is the line between defensible display and marketing fiction. The codebase's existing habits (personal percentiles, honest absence, no black-box weighting) are already on the right side of that line.

---

## 4. Mind-body sessions — the yoga rule

### Why the current model mishandles yoga

Today yoga logged as `.exercise` is *activating*: it gets a TRIMP Load, a suppression axis, and workout-style expectations. Every one of those fails for mind-body work:

- **TRIMP is invalid for yoga** on four documented counts: HR–VO2 dissociation (isometric pressor reflex, heat, inversions — [CTCP 2019](https://www.sciencedirect.com/science/article/abs/pii/S1744388118303025)), HR being a *deliberately manipulated input* under pranayama (a load model whose input the activity controls is unidentifiable), the floor effect (yin → TRIMP ≈ 0 → "no dose" while the real dose — vagal activation, BP and cortisol reduction — is documented but lives off the HR axis), and the wrong dose construct (yoga's benefits aren't cardiorespiratory-fitness adaptations).
- **In-session HRV flips sign**: yoga shows vagal dominance *during* practice ([Tyagi & Cohen 2016](https://pubmed.ncbi.nlm.nih.gov/27512317/); [Herbert 2021](https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2021.731645/full)), and slow paced breathing (~4.5–6.5 brpm) mechanically maximizes RSA — **RMSSD is not a valid parasympathetic measure during slow breathing** ([Am J Physiol 2023](https://journals.physiology.org/doi/full/10.1152/ajpregu.00272.2022)). Never interpret in-session HRV for yoga without breath rate.
- **What the code already gets right — say so:** the `vagalRose` flag detects DC *rising* with %HRR and refuses to score suppression ("vagal tone rose — nothing suppressed"), returning flagged-never-scored. That is precisely the correct refusal, and the flag is the app's best measured evidence that a session was restorative. Likewise Yoga/Pilates/Stretching already sit in `motionMisleadingSubtypes` (no fabricated efficiency), and the restorative class with benefit-signed deltas exists for meditation. The pieces are all built; they're just not connected to classification.

### Classification: label vs measured — both options

- **Option A (current): the label decides.** `measuredClass` returns `activityTypeEnum.activityClass`; the measured-rise machinery (`activatingHRRise = 15`) is dead code and the v7 comment is stale. Pro: predictable, user-controlled. Con: one "Yoga" label spans yin (near-rest) to power vinyasa (~78% of class in moderate-vigorous zones) — no single label-based treatment can be right for both ends.
- **Option B (research-backed): measure the session.** The best-separating strap-available features: **time above 40% HRR**, **posture-transition rate from chest motion** (yin ~0.2–0.3/min vs several/min in flow), and **breath rate** (paced 4–8 brpm vs metabolic 15+). Classify **restorative / mixed / workout**; validate with the sign of post-session ΔRMSSD (immediate rebound up = restorative dose; suppression 5–65+ min = workout dose — the vinyasa crossover trial [PMC10684087](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC10684087/) shows moderate vinyasa behaves like exercise).

**Recommendation: Option B with the label as prior, plus a visible override.** The label sets the expectation; the measurement (time>40%HRR + transition rate + `vagalRoseDuring` + post-ΔRMSSD sign) sets the class; when they disagree, show why ("logged as Yoga, measured as a workout — 34 min above 40% of your reserve"). This finally makes the v7 comment true. For *mixed* sessions, segment phases by HR + motion (flow vs floor/savasana) and credit each phase to its channel.

### What to score — two decoupled channels, never one number

- **Channel A — Training load** (legitimately ~0 for yin): sRPE × minutes as the cross-modality currency (validated where HR load fails — [PMC6162408](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6162408/)); plus TRIMP only for workout-classified time (the vinyasa end).
- **Channel B — Regulation credit**: ΔRMSSD pre→post measured 5–15 min post under *spontaneous* breathing (the stored before/after RMSSD windows already provide this — the after-window just needs a paced-breathing exclusion); end-of-session HR vs pre; **breathwork dose = minutes at ≤6–8 brpm** (respiratory rate is the honest pranayama dose, not HRV).

### What NOT to score

- No TRIMP headline for restorative-class time (floor effect asserts "no dose" falsely).
- No suppression/efficiency axes (already correctly refused via `vagalRose` — keep).
- No in-session RMSSD as a recovery signal during paced breathing (RSA artifact); no "low HF = stress" during slow breathing (the oscillation moves to LF by design).
- No HRR60 framing — the "recovery" expectation flips: after gentle yoga the *absence* of suppression plus an immediate vagal rebound **is** the good outcome.

### Day-level readout

Frame yin/breathwork as **recovery contribution** (a credit, like sleep), vinyasa as light-moderate cardio load *plus* the closing-phase regulation credit. Day-level effects are real but small: reduced waking/evening cortisol ([Pascoe 2017](https://www.sciencedirect.com/science/article/abs/pii/S0306453017300409)), same-day stress-reactivity buffering ([IJSEP 2022](https://www.tandfonline.com/doi/abs/10.1080/1612197X.2022.2084762)), transient BP/HR drops. Detect them the only honest way: **that night's RMSSD/RHR vs the 14-day personal baseline, yoga-day vs matched non-yoga days** — a paired within-person comparison, not population thresholds. This slots directly into the existing restorative-model machinery (`impactDeltaPct`/`impactCoverage`).

---

## 5. Migration path — ordered slices, smallest first, each shippable

1. **Re-headline the row (no schema change).** Swap the composite hero for the three top-line numbers — Effort (`exerciseLoad` + personal quantile banding computed from history), Intensity (stored domain/zone seconds), Recovery (`hrr60Bpm` vs personal same-end-intensity baseline) — plus the generated sentence. Delete crown/laurel and the string-keyed gating. Move Readiness to a context line. Every input is already stored; this is UI + two banding computations. **Bump the backfill version if any new derived value is persisted** (memory-noted trap: ActivityLog changes stay invisible on existing sessions otherwise).
2. **Split Bounce-back; demote Suppression/Efficiency.** HRR60 stands alone; half-recovery and afterTailDC become the recovery-timeline block; brakePerBeat becomes the "what it cost" tile; delete the dead decoupling term and `reactivationScore`; either anchor efficiencyScore like suppression or mark it exploratory. Restructure the detail screen into the four story blocks.
3. **Fix classification.** Implement measured three-way class (time>40%HRR from stored zone seconds + `vagalRoseDuring` + post-ΔRMSSD sign from stored window averages — all available today), label as prior, visible disagreement note. Update the stale v7 comment. Ships the core yoga fix with zero new sensors.
4. **Artifact gating.** Store `artifactPct` from the quality filter (backfill v9); gate and badge all DFA-a1 outputs at the ~5% threshold. Small, and it protects the credibility of the Intensity headline.
5. **Mind-body channels.** sRPE prompt (strength + mind-body subtypes); breath-rate estimate (RSA-derived) → `minutesSlowBreathing`; posture-transition rate from motion; two-channel display (load / regulation credit); wire the day-level yoga-day-vs-matched-days readout into the restorative impact model.
6. **Long-term screen.** 7-day rolling ln RMSSD vs SWC band + CV flag; RHR trend; acute/chronic EWMA as two lines; Foster monotony/strain caption. All computable from DailyAnchor + stored `exerciseLoad`. Add `driftPercent` on matched steady sessions to start the decoupling trend accruing.
7. **Series storage.** Downsampled in-session series (`sessionSeriesBlob`) unlocks the a1 timeline with HRVT lines, a1-vs-HR divergence plot, per-zone TRIMP, interval-aware cost, and gated warm-up tau — the full DETAIL tier, and eventually threshold-anchored TRIMP from personal HRVT1/HRVT2.

Each slice leaves the app coherent; slices 1–3 deliver the owner's core complaint (confusing summary, mishandled yoga) using only data already on disk.
