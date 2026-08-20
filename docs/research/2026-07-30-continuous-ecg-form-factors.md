# Continuous ECG as a tracked variable — form-factor research

Date: 2026-07-30
Question: what is the most elegant way to capture ECG in real time, continuously, as a
variable — ideally something garment-based (underwear, shorts, leggings, bra, shirt)
rather than a Polar-H10-style strap.

Research was partially truncated by a session limit. Three of eight research threads
completed in full (electrode failure physics; Japan/Korea/China/Taiwan market; silicon
and dev boards). Threads on Western adhesive patches, novel form factors (ear, ring,
ambient), and iOS/HealthKit integration were cut off mid-run and are covered here from
prior knowledge, flagged as lower confidence.

---

## 1. Verdict

**The garment is the wrong place to put the electrode, and the market has already
voted.** Not because the textile engineering is bad, but because of two hard physical
constraints that no amount of DSP or industrial design removes:

1. **Dry textile electrodes lose to gel by three orders of magnitude in contact
   impedance, and the gap does not close over time.** Over 48 h of continuous wear,
   solid metal electrodes settle from 100–200 kΩ down to 20 kΩ. Conductive fabric never
   gets below 3–5 MΩ at any point, moving or stationary.
   ([Sci Rep 14, 2024](https://pmc.ncbi.nlm.nih.gov/articles/PMC11024137/))

2. **The contact-pressure window that textile electrodes need barely overlaps with the
   pressure a comfortable garment delivers.** Electrodes want ~10–20 mmHg. Measured
   pressure at the chest for typical sportswear is ~8.6 mmHg — below the 7.5 mmHg
   impedance knee and inside the band where papers report "poor, fluctuating R-peaks."
   Push above ~20–25 mmHg and artifact *returns* (DC-offset effects) while subjects
   report discomfort. ([Polymers 10:663](https://pmc.ncbi.nlm.nih.gov/articles/PMC6404358/),
   [Sci Rep 9:5897](https://pmc.ncbi.nlm.nih.gov/articles/PMC6459913/),
   [BioMed Eng OnLine 12:26](https://pmc.ncbi.nlm.nih.gov/articles/PMC3637835/))

The consequence, measured in real ambulatory cohorts rather than on the bench:

| Study | Setting | Result |
|---|---|---|
| Martins 2025, textile belt, n=242 overnight | sleeping | 49.7% of recording is worst-class; only **1.0%** of that class yields accurate RR |
| same, n=9 activity protocol | cycling/walking/running/squats | best-quality data fell **34.7% → 0%** |
| same, home vs hospital | free-living | unusable fraction **6× worse** at home than gel electrodes |
| Hexoskin shirt, n=36 children, 24 h | free-living | **94.9% → 80.0%** accuracy, first vs second 12 h (p<0.001) |

Sources: [Sci Rep 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC12639010/),
[JMIR Form Res 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC12483337/)

The 48-hour endpoint is the one that settles it. Under controlled 2 Hz / 4 mm motion
(jogging foot-impact frequency), SNR by electrode material:

| Material | 0 h moving | 48 h moving |
|---|---|---|
| Platinum | 29.7 dB | **31.6 dB** |
| Stainless steel | 29.4 dB | 26.5 dB |
| Silver | 30.0 dB | 24.2 dB |
| Conductive polymer | 10.7 dB | 18.2 dB |
| Conductive fabric | 8.2 dB | **−1.9 dB** |

Negative SNR means the noise is larger than the ECG, in an overlapping frequency band.
There is no filter that recovers information from that.

---

## 2. Why underwear / shorts / yoga pants specifically will not work

Separate from electrode chemistry, the *placement* is electrically wrong.

ECG measures the projection of the heart's dipole vector onto the line between two
electrodes. Two things kill a waistband lead:

- **Distance.** QRS amplitude falls off sharply with distance from the thorax. A
  waistband sits at roughly L3 — well below the heart.
- **Symmetry.** Left and right waistband electrodes are approximately equidistant from
  the heart, so the differential projection of the cardiac vector onto that horizontal,
  inferior line is close to null. You are subtracting two nearly identical signals.

Meanwhile the waistband is sitting on top of the abdominal muscles, so the differential
you *do* get is dominated by EMG in the same 10–30 Hz band as the QRS. Leggings and
shorts are worse again: any waistband-to-thigh vector adds quadriceps EMG and the
largest motion artifact source on the body.

The bra band and the chest band are the only garment placements that are electrically
defensible, because they straddle the thorax at roughly heart level. This is why
Myant's Skiin line puts its electrodes on a band that sits at the base of the ribcage
rather than at the hips, and why every serious garment product is a shirt, vest, or
bra — never trousers.

**Practical read: "smart yoga pants that measure ECG" is not an engineering gap waiting
to be filled. It is physically the wrong geometry.**

---

## 3. What happened to the smart-garment market

Verified in full for Japan/Korea/China/Taiwan. The pattern is a consumer collapse and a
retreat into regulated medical services that quietly dropped the textile part.

**Japan — consumer textile ECG is dead:**
- **hitoe (NTT + Toray)** — news page's last entry is 2023-06-15. docomo terminated
  transmitter support in 2021. Toray Medical's Wearable ECG System II is marked
  販売終了 (discontinued). What survived is a Class II Holter service using a
  **single-use belt electrode**, not a shirt. Closed, no SDK.
- **Goldwin C3fit IN-pulse** — page still renders but prices are pre-Oct-2019
  consumption-tax figures. Abandoned in place.
- **Toyobo COCOMI** — technically the best material in the cluster (0.3 mm film,
  ≤1 Ω surface resistance, gel-free, 100+ wash cycles). Both Toyobo URLs 301-redirect
  to `cocomi.toyobostc.com`, which does not resolve (NXDOMAIN). Retailer delisted it.
  No formal announcement, but three dead hostnames is a strong signal.
- **Mitsufuji** — company is healthy and growing, but the growth product is a **PPG
  wristband** (hamon band; ~2,500 units to Yamato Transport, May 2025). Silver-fiber
  ECG wear is now a contract offering with no public spec sheet.
- **Xenoma e-skin ECG** — alive and genuinely good (3-channel CC5/CM5/NASA, **1000 Hz**,
  0.67–40 Hz, Class II 認証 304AFBZX00001000, insurance-covered since 2022). But it is a
  **mail-in service** — patients are told *not to wash it*, they bag it and ship it back.
  Its developer SDK exposes strain/accel/gyro only, no ECG, last versioned 2017.

**Korea — no shipping textile-ECG garment found at all.** Every MFDS-cleared Korean ECG
device is a watch or a patch (Samsung Health Monitor, Garmin ECG, Mezoo HiCardi, HUINNO).
Wave Company sells ElecSil conductive silicone rated for ECG/EMG but publishes no specs,
prices, or clearances — a component supplier, not a product.

**China — the only region actually shipping registered washable ECG garments:**
- **Shenzhen Benefm** — 8-channel / 12-lead, 1000 Hz, 0.05–250 Hz, CMRR >110 dB,
  machine washable, **NMPA Class II 粤械注准20202071589**. ~¥22,000 hospital version.
  Data terminates in their BMHolter cloud; no public SDK.
- **Lifesense 乐心 (SZ:300562)** — 10 fabric electrodes, 12-lead, Guangdong provincial
  Class II (late 2024), sold on JD.com. Closed.
- **BodyPlus** — consumer/sports tier at **¥455**. An order of magnitude below anything
  Japanese. No lead count or regulatory claim published.

**Taiwan — AiQ Smart Clothing (BioMan+, 1–3 lead) was acquired by Myant (Toronto) via a
JV with TexRay, announced 2026-01-21.** Note many secondary sources misdate this to
August 2025; the primary statement says January 2026. The statement does not commit to
BioMan+'s future. AiQ is ODM-only — no e-commerce, contact sales — which paradoxically
makes it one of the more tractable counterparties if you want raw sample access by
contract.

**Developer access ranking across the whole Asian cluster** (best to worst):
Union Tool myBeat (SDK is a purchasable catalog item, ¥27,500) → AiQ/Myant (ODM
contract) → Benefm / Lifesense (closed, vendor cloud) → hitoe/NTT-TX (closed, regulated
SaMD) → Xenoma (closed *and* physically mail-in).

Only two vendors in the entire region publish a sampling rate (Xenoma and Benefm, both
1000 Hz). **Nobody publishes bit depth. Nobody advertises one-pod-many-garments.**

---

## 4. The reframe that actually solves the problem

The measured data points at a product answer that is different from the one the question
assumes.

Textile and dry electrodes are **fine at rest and bad in motion**. Class 1 + Class 2
signal quality covers ~45% of an overnight recording, and >99% of those segments give
accurate RR. During an activity protocol, top-quality data goes to zero. The Hexoskin
degradation is a *drying* curve, not a wear-time curve.

So do not model ECG as a 24/7 continuous stream. Model it as:

- **Morphology-grade ECG in quiet windows** — sleep, seated rest, morning stillness.
  This is where dry electrodes actually deliver, where the impedance has had 10–15
  minutes to settle, and where the clinically interesting variables live anyway
  (nocturnal HRV, ectopy burden, AF episodes, sleep-staged autonomic tone).
- **PPG for the always-on trend** — the continuous variable that fills the other 16
  hours, already available from the watch/ring the user is wearing, no new hardware.
- **ECG on trigger** — spot capture when PPG flags something, or on user demand.

This is, notably, exactly what Apple converged on: 30-second spot ECG plus continuous
PPG-based AFib History. Not a compromise born of laziness — it is the shape the physics
forces.

---

## 5. Hardware options, by tier

### Best developer access, shipping today
**Movesense (Suunto spinoff)** — open SDK, custom firmware, raw ECG streaming, sensor
snaps onto a standard textile chest strap so the *textile is a consumable and the pod is
reusable*. Movesense Medical carries CE MDR. This is the architecture the Asian vendors
notably fail to offer. *(Lower confidence — the agent covering this was truncated;
verify current SDK state and sampling-rate options.)*

**Polar H10 + polar-ble-sdk** — raw ECG at 130 Hz over the PMD service. Explicitly
rejected as a form factor, but it is the baseline any alternative has to beat on signal
quality, and it is the reference to validate anything else against.

### Medical grade, limited access
**Bittium Faros 180/360** — up to 1000 Hz, medical grade, but OEM/limited developer path.
**VitalConnect VitalPatch**, **iRhythm Zio** — closed clinical loops.

### The closest thing to the original vision
**Myant Skiin** — underwear and bras with ECG at the ribcage band, now consolidated with
AiQ's manufacturing. This is the one product line genuinely pursuing what the question
describes. Open question is whether third-party raw sample access exists at all.

### Silicon, if building custom
Verified in full. Headline: **the three obvious dev platforms are all wrong.**

- **TI ADS1292R / ADS1298 eval kits** — USB-only, MMB0 motherboard, **Windows XP SP2 /
  Windows 7** LabVIEW tooling, out of stock on TI.com (DigiKey $140 / $264). TI's own
  user guide says the ADS1x98ECG-FE "is NOT a reference design." No BLE anywhere.
- **AD8232** — analog amplifier with **no ADC**, band-limited to **0.5–40 Hz** in the
  cardiac config, CMRR only 80 dB, 14 µV p-p noise. Fine for R-peaks, useless for
  morphology. 13-year-old part.
- **Cooking Hacks e-Health** — dead since 2019-12-20. Three community repos, 3 stars
  combined, newest commit nine years old.

The part that should actually be used is **MAX30003**: 18-bit (15.5 ENOB), **5 µV p-p**
noise, **85 µW at 1.1 V**, >500 MΩ input impedance, ±650 mV offset tolerance, SPI with a
32-word FIFO, and **hardware R-to-R detection with interrupt** so the MCU can sleep. That
last feature is what makes multi-day wear plausible. Open-source breakout with KiCad
files and Arduino library under CERN-OHL-P v2:
[Protocentral/protocentral_max30003](https://github.com/Protocentral/protocentral_max30003).

Also worth noting: **the amplifier is never the bottleneck.** Measured intrinsic noise —
conductive fabric electrode 264 µV p-p vs. the amplifier alone at 6.98 µV p-p. The
electrode contributes 25–60× the AFE. Buying a better front end does essentially nothing.

Reference designs: **TIDA-01580** (AFE4900 + CC2640R2F, BLE 5, **30 days on a CR3032**)
is the right topology to copy. **TIDM-1005 does not appear to exist** — bad part number.

---

## 6. Integration constraints (lower confidence — agent truncated)

- **HealthKit `HKElectrocardiogram` is believed read-only for third parties.** A
  third-party device's ECG likely cannot be written into HealthKit as a first-class ECG
  sample. Verify against current Apple docs before designing around it.
- **There is no standard BLE GATT service for ECG waveforms.** Heart Rate Service 0x180D
  gives BPM and RR intervals only. Every vendor uses a proprietary service — Polar's PMD,
  Movesense's own API, etc.
- **Bandwidth sanity check:** 250 Hz × 16-bit × 1 channel ≈ 500 B/s ≈ 4 kbit/s. Trivially
  within BLE. The constraint is not throughput, it is iOS background execution and the
  phone's battery cost of holding a connection for 24 h — which further supports the
  windowed-capture model in §4.
- **Regulatory line:** HRV, heart rate, signal quality, and logging are safe wellness
  claims. AF detection, arrhythmia notification, ischemia, and QT analysis trigger FDA
  SaMD / EU MDR Class IIa. Verify specifics.

---

## 7. What to do next

1. Validate the windowed-capture hypothesis before buying anything: take existing Polar
   H10 or equivalent raw ECG, segment by accelerometer activity level, and measure what
   fraction of a night and a day yields morphology-grade signal. If the ~45%-overnight /
   0%-during-activity split reproduces, the product design follows directly.
2. Pick the pod-plus-consumable-textile architecture (Movesense-style), not the
   integrated-garment architecture. It sidesteps washability, sizing, and the
   one-pod-many-garments problem that no vendor has solved.
3. Treat ECG as an episodic high-fidelity variable feeding derived metrics, with PPG
   carrying continuity.

---

## 8. KardiaMobile / AliveCor (verified 2026-08)

**Category: spot check, not a variable.** Every Kardia device requires the user to place
fingers on electrodes for a 30-second recording. There is no ambulatory or continuous
mode, by design. KardiaMobile 6L "captures a 6-lead, medical-grade ECG in 30 seconds"
and adds a left-knee/ankle contact for the limb leads.

Determinations reported by the 6L (per AliveCor): atrial fibrillation, bradycardia,
tachycardia, sinus rhythm with PVCs, sinus rhythm with wide QRS, sinus rhythm with SVE.
Explicitly does not check for heart attack.

**Developer access — better than expected, but offline only.** AliveCor's GitHub org
states plainly that "most of our code is closed" and there is no SDK for live data. But
they publish the file-format tooling, which means the raw waveform is fully recoverable
from exported recordings:

- [AliveCor/ATCpy](https://github.com/AliveCor/ATCpy) — Python reader/writer.
  `ATCReader(...).get_ecg_samples(1)`. Last pushed **2021-09-30**, 5 stars, **no license
  file**.
- [AliveCor/atc2json](https://github.com/AliveCor/atc2json) — Go converter. Last pushed
  **2025-03-26**, so still maintained.

ATC structure, read directly from `atc2json/atc2json.go`:

```go
type FmtBlock struct {          // format block
    Format     byte
    Frequency  uint16           // sampling rate
    Resolution uint16           // units per mV
    Flags      byte
    Reserved   uint16
}
type EcgSamples struct {        // little-endian int16, one block per lead
    LeadI   []int16 `json:"leadI"`
    LeadII  []int16 `json:"leadII,omitempty"`
    LeadIII []int16 `json:"leadIII,omitempty"`
    AVR     []int16 `json:"aVR,omitempty"`
    AVL     []int16 `json:"aVL,omitempty"`
    AVF     []int16 `json:"aVF,omitempty"`
}
```

Plus an `InfoBlock` with DateRecorded, RecordingUUID, PhoneUDID, PhoneModel,
RecorderSoftware/Hardware, Location, and a `mainsFrequency` field (50/60 Hz). Conversion
is `calcMillivolts(samples, amplitudeResolution)`; the unit test uses scale = 2000, i.e.
**2000 units/mV = 500 nV per LSB, 16-bit signed**.

So: **full six-lead 16-bit raw waveform, recoverable from an exported `.atc` file.** What
does not exist is any way to get it live, or any documented path for a third-party iOS
app to read Kardia recordings from the Kardia app. The referenced *Alive File Format
Specification 1.6* Google Doc now returns **401** — the parsers are the surviving
documentation.

**Verdict for a metrics app:** useful as an episodic high-fidelity reference — a
validation ground truth to check derived metrics against, or a user-initiated event —
but structurally incapable of being the continuous variable. Sampling rate (widely cited
as 300 Hz) was not confirmed from a primary source; it is a header field, so read it from
an actual file rather than assuming.

---

## 9. ECG patches and pods (verified 2026-08)

Patches solve the problem §1 identifies: they use **gel Ag/AgCl at ~0.5 kΩ** instead of
dry textile at 3–5 MΩ. That is the entire reason they work. The price is a consumable and
skin tolerance over weeks of wear.

The dividing line that matters is **live BLE stream vs. record-and-mail**. Most clinical
patches are the latter.

### Streams live, open developer access

**Movesense — the recommendation.** Verified from the API reference:
- Sampling rates: **125, 128, 200, 250, 256, 500, 512 Hz**
- Raw path `/Meas/ECG/{rate}`, **LSB = 0.38147 µV**; mV float path added in v2.3
- Subscribe model, 16 samples per notification; `/Meas/HR` gives HR + RR intervals
- **Custom C++ firmware on the sensor** (`#include <meas_ecg/resources.h>`)
- **Caveat straight from the docs: ">256 Hz over BLE should be avoided"** — the AFE FIFO
  overflows. For higher rates you process on-sensor. This is a real design constraint.
- **Movesense MD**: clinical-grade single-channel ECG, **Class IIa MDR 2017/745**
- **Movesense Flash**: **128 MB internal memory for autonomous logging**, RR intervals at
  1 ms resolution — this is the one that survives without a phone connected
- **Movesense HR2**: 1-lead non-medical, **9.4 g**
- Pod-plus-swappable-attachment architecture, which is exactly the shape §4 argues for

**Cortrium C3+ — the dark horse for openness.** 3 ECG channels + respiration,
per-channel enable, raw *and* filtered samples exposed via a documented
`ConnectionManager` / `EcgDataListener` API. Streams over the **Nordic UART Service**
(`6E400001-B5A3-F393-E0A9-E50E24DCCA9E`, TX `...0003`), independently confirmed by
[cortrium-ble-mqtt](https://github.com/BenediktBlana/cortrium-ble-mqtt) which decodes the
delta-compressed packet format. Official repo was deleted but survives as
[kikebodi/AndroidApp](https://github.com/kikebodi/AndroidApp). Caveats are serious: the
BLE stack itself is a closed AAR from a dead `localhost` Maven repo, the code is ~2017
era, and there is **no FDA clearance** (CE only, zero openFDA records).

### Streams, but closed

**Bittium Faros** — 1–3 channels, **up to 1000 Hz adjustable**, 7 days battery (Faros
180L: 250 Hz, 14+ days). CE Class IIa + FDA 510(k) **K182030**. Bluetooth present, but
no public SDK or documented GATT profile.

**Vivalnk — "SDK" is marketing, and the specs don't reconcile.** Its own IFU states the
patch "will not connect or transfer data to any devices that does not use VivaLNK
provided SDK package… proprietary… cannot be intercepted." AES-128, contact-gated. The
`github.com/vivalnk` org has 3 stale repos, newest 2018, none an SDK. Worse: the website
claims **14-day battery / IPX7 / 30-day cache** while its own VV330 IFU says **3 days /
IP25 / 24-hour cache**, and FDA **K191870** confirms 3 days. Treat vendor web specs as
unreliable.

### No radio at all — record and mail back

- **Bardy CAM** — spec sheet DN000697B has **no radio section**. 1 channel, **171 Hz**,
  bandwidth **0.67–25 Hz** (unusually narrow — no ST analysis), non-rechargeable coin
  cell, IP23. FDA K233110.
- **Philips ePatch** — 1/2/3 channels, **128/256/512/1024 Hz, 16-bit**, 0.05 Hz HPF,
  CMRR >80 dB, 10 MΩ, 2 GB internal, micro-USB offload. 3–14 days single-channel.
  Technically the best signal chain here, and completely unreachable in real time.
- **Byteflies** — 2-channel biopotential + IMU, store-and-forward through a proprietary
  docking station to Byteflies Cloud. CE IIa, FDA K192549.

### Regulatory reference (openFDA, authoritative)

Zio monitor K202359 / K243650 · Zio AT K240177, K240029 · ZEUS K222389, K252859 ·
BodyGuardian K192732 / K151188 / K121197 · VitalPatch K183078, K190916, K192757 ·
VitalRhythm K242129 (Apr 2025) · Bardy CAM K233110 · Isansys K172329 · Smartcardia
K231276 + K240653 MCT · Nanowear K201669, K212160, K232053 · LifeSignals K200690,
K242018, K261569 (Jul 2026) · Sibel ANNE Chest K240251, ANNE Maternal K253021 (Feb 2026)
· InfoBionic MoMe ARC K250356 (Jul 2025) · Bittium Faros K182030. Cortrium and Element
Science have **no 510(k)**.

**Research note:** `accessdata.fda.gov/cdrh_docs/pdfNN/KNNNNNN.pdf` returns 404 to
default clients but **200 with a browser User-Agent** — use `curl -A`. The openFDA JSON
API (`api.fda.gov/device/510k.json?search=applicant:"X"`) is unauthenticated and is the
reliable route.

---

## Evidence gaps

- Patches and Kardia now covered in §8–9. Still missing: iRhythm and Preventice technical
  specs, VitalConnect sampling rate/bandwidth, Isansys sampling rate, and **essentially
  all consumable and per-unit pricing** — the weakest dimension. The route in is CPT
  93241–93248 reimbursement plus iRhythm's 10-K revenue-per-device disclosure.
- Novel form factors (ear-ECG, rings, capacitive seat/bed, Casana toilet seat, Withings
  Body Scan) — agent truncated, never re-run.
- KardiaMobile sampling rate (commonly cited as 300 Hz) unconfirmed from primary source.
  It is a header field — read it from a real `.atc` file.
- iOS/HealthKit/regulatory specifics — agent truncated; §6 is prior knowledge, unverified.
- No published in-garment measurement of triboelectric noise amplitude in mV exists.
  TENG literature suggests fabric-on-fabric contact generates 10²–10³ V open-circuit
  against a 10⁻³ V ECG, but that is an upper bound under optimized geometry.
- The contact-pressure optimum papers are mostly **n=1** and their optima disagree by 3×
  (7.5 to 30 mmHg). The "10–20 mmHg" synthesis is an interpretation, not any single
  paper's finding.
