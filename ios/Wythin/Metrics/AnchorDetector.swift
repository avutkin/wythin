import Foundation

// MARK: - Thresholds

/// Every gate the day's rested anchor must clear. One place, so the
/// stillness threshold can be calibrated against real captures.
enum AnchorThresholds {
    /// ACC magnitude SD (mg) below which the window counts as still.
    static let stillnessSD: Float = 20
    /// Fallback when `motion` is absent (backfilled history): SD of HR, bpm.
    static let hrStabilitySD: Float = 3
    static let maxInvalidRate: Float = 0.05
    static let minECGTier: Int = 1
    static let breathRange: ClosedRange<Float> = 8...20
    /// Preferred window length — below this DC is dropped from the score.
    static let preferredMinSec: Double = 300
    /// The span the medians are taken over, however long the rest ran. A
    /// 12-minute rest and a 70-minute rest must produce comparable numbers,
    /// which they cannot if the median follows whatever the morning allowed.
    static let anchorWindowSec: Double = 300
    /// Absolute minimum window length.
    static let minSec: Double = 180
    /// Windows starting before this hour are preferred over later ones.
    static let morningCutoffHour: Int = 12
    /// Rejected samples tolerated inside a run before it counts as broken. A
    /// stir of one or two ticks is not the end of a rest; a sustained one is.
    /// Expressed in samples rather than seconds so the rule holds at both the
    /// 2 s foreground and the 30 s background tick rate.
    static let maxRejectedInGap: Int = 2
    /// Wall-clock hole beyond which two stretches are separate rests however
    /// clean they are — nothing was rejected because nothing was recorded
    /// (app killed, strap off, BLE dropped).
    static let maxGapCeilingSec: Double = 120
    /// A run must carry this many samples whatever its span. At 30 s ticks a
    /// 3-minute run is 6 points, and a median over fewer is not a median.
    static let minSamples: Int = 6
}

// MARK: - Reading

enum AnchorConfidence: String, Codable { case high, medium, low }

/// One day's rested-window reading. Frozen once captured.
struct AnchorReading: Equatable {
    let startedAt:   Date
    let durationSec: Double
    /// Fractional local hour of `startedAt` (7.5 = 07:30).
    let hour:        Double
    let lnRMSSD:     Float
    let dc:          Float?
    let restingHR:   Float
    let pip:         Float?
    let dfa1:        Float?
    let breathBPM:   Float?
    let late:        Bool
    let motionKnown: Bool
    let confidence:  AnchorConfidence

    var day: Date { Calendar.current.startOfDay(for: startedAt) }
}

// MARK: - Detector

/// Finds the first *rested* window of a day — the standardized condition the
/// day's capacity score is built on. Pure: no persistence, no clock beyond
/// what is passed in.
///
/// Standardization is the point. The daily-monitoring literature (Plews et
/// al.) depends on posture, time of day and condition being held constant;
/// a day average moves with whatever the person happened to be doing, which
/// measures load rather than capacity.
enum AnchorDetector {

    static func detect(_ points: [MetricsHistoryPoint], now: Date = .now) -> AnchorReading? {
        // Sorted but NOT pre-filtered: `continuousRuns` needs to see the rejected
        // samples, because a rejected sample is what distinguishes "the rest
        // ended" from "the tick loop was throttled".
        let all = points.sorted { $0.timestamp < $1.timestamp }
        guard !all.isEmpty else { return nil }

        let runs = continuousRuns(all).filter { run in
            // Every gate is applied to the leading window — the span the
            // medians actually come from — not to the whole rest. Two reasons:
            // a run must not pass on motion known somewhere in its tail while
            // the window the anchor is built from never had it, and a run whose
            // head is too sparse to median must be *skipped* so a later, denser
            // rest can still anchor the day. Checking the sample count only
            // inside `reading` made one unusable run fatal for the whole day.
            let window = leadingWindow(run)
            return window.count >= AnchorThresholds.minSamples
                && duration(run) >= AnchorThresholds.minSec
                && passesRunGates(window)
        }
        guard !runs.isEmpty else { return nil }

        let cal = Calendar.current
        let morning = runs.first { run in
            cal.component(.hour, from: run[0].timestamp) < AnchorThresholds.morningCutoffHour
        }
        guard let run = morning ?? runs.first else { return nil }

        return reading(from: run, late: morning == nil)
    }

    // MARK: Gates

    private static func passesPointGates(_ p: MetricsHistoryPoint) -> Bool {
        // `signalQuality` is defined as `1 - rrInvalidRate` (MetricsEngine), so
        // the two fields are one measurement stored twice. Rows written before
        // `rrInvalidRate` existed carry only `signalQuality` — require whichever
        // is present rather than both, or backfilled history is thrown away for
        // being old rather than for being bad.
        guard let invalid = p.rrInvalidRate ?? p.signalQuality.map({ 1 - $0 }),
              invalid <= AnchorThresholds.maxInvalidRate else { return false }
        // An absent tier means the row predates the field, not that the ECG was
        // poor. Tolerated, and paid for in confidence — exactly as absent
        // `motion` is.
        if let tier = p.ecgQualityTier, tier < AnchorThresholds.minECGTier { return false }
        guard p.vti != nil, p.meanBPM != nil else { return false }
        if let m = p.motion, m > AnchorThresholds.stillnessSD { return false }
        if let b = p.breathBPM, !AnchorThresholds.breathRange.contains(b) { return false }
        return true
    }

    /// When motion is unknown across the window the medians come from, fall
    /// back to HR stability. Callers pass the window, not the whole run — a
    /// tail that was instrumented says nothing about the head that is measured.
    private static func passesRunGates(_ window: [MetricsHistoryPoint]) -> Bool {
        let motionKnown = window.contains { $0.motion != nil }
        guard !motionKnown else { return true }
        let hrs = window.compactMap { $0.meanBPM }
        guard hrs.count >= 2 else { return false }
        return sd(hrs) <= AnchorThresholds.hrStabilitySD
    }

    // MARK: Assembly

    /// One pass over the raw stream. A sample that fails the point gates is not
    /// dropped silently — it is counted, because it is evidence the rest ended.
    ///
    /// Note the caller applies `MetricsQualityFilter` first, which removes
    /// strap-off samples entirely. Those read as absence rather than rejection
    /// here, which is right: taking the strap off is not stirring. The
    /// `maxGapCeilingSec` ceiling is what catches a long removal.
    private static func continuousRuns(_ all: [MetricsHistoryPoint]) -> [[MetricsHistoryPoint]] {
        var runs: [[MetricsHistoryPoint]] = []
        var current: [MetricsHistoryPoint] = []
        var rejectedSinceLast = 0

        for p in all {
            guard passesPointGates(p) else {
                rejectedSinceLast += 1
                continue
            }
            if let last = current.last {
                let hole = p.timestamp.timeIntervalSince(last.timestamp)
                if rejectedSinceLast > AnchorThresholds.maxRejectedInGap
                    || hole > AnchorThresholds.maxGapCeilingSec {
                    runs.append(current)
                    current = []
                }
            }
            rejectedSinceLast = 0
            current.append(p)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func duration(_ run: [MetricsHistoryPoint]) -> Double {
        guard let first = run.first, let last = run.last else { return 0 }
        return last.timestamp.timeIntervalSince(first.timestamp)
    }

    private static func reading(from run: [MetricsHistoryPoint], late: Bool) -> AnchorReading? {
        // The whole qualifying rest — this is what the provenance line reports,
        // and what DC's stability requirement is judged on.
        let dur = duration(run)

        // The standardised head of it — this is what the medians see. The
        // sample-count guard is belt and braces: `detect` already filtered runs
        // on it, so a run that reaches here cannot fail it.
        let window = leadingWindow(run)
        guard window.count >= AnchorThresholds.minSamples,
              let lnRMSSD  = median(window.compactMap { $0.vti }),
              let restingHR = median(window.compactMap { $0.meanBPM }),
              let start = window.first?.timestamp else { return nil }

        // DC is a phase-rectified statistic — it needs the longer record to be
        // stable, so a short rest drops it rather than reporting it noisily.
        let longEnoughForDC = dur >= AnchorThresholds.preferredMinSec
        let motionKnown = window.contains { $0.motion != nil }
        let ecgKnown    = window.contains { $0.ecgQualityTier != nil }

        let cal = Calendar.current
        let hour = Double(cal.component(.hour, from: start))
                 + Double(cal.component(.minute, from: start)) / 60

        let confidence: AnchorConfidence
        if !motionKnown || !ecgKnown     { confidence = .low }
        else if longEnoughForDC && !late { confidence = .high }
        else                             { confidence = .medium }

        return AnchorReading(
            startedAt:   start,
            durationSec: dur,
            hour:        hour,
            lnRMSSD:     lnRMSSD,
            dc:          longEnoughForDC ? median(window.compactMap { $0.dc }) : nil,
            restingHR:   restingHR,
            pip:         median(window.compactMap { $0.pip }),
            dfa1:        median(window.compactMap { $0.dfa1 }),
            breathBPM:   median(window.compactMap { $0.breathBPM }),
            late:        late,
            motionKnown: motionKnown,
            confidence:  confidence)
    }

    /// The first `anchorWindowSec` of a run, half-open so the span is exactly
    /// the constant rather than one tick more. Shorter runs are returned
    /// whole — they have no tail to trim.
    private static func leadingWindow(_ run: [MetricsHistoryPoint]) -> [MetricsHistoryPoint] {
        guard let start = run.first?.timestamp else { return run }
        let cutoff = start.addingTimeInterval(AnchorThresholds.anchorWindowSec)
        return Array(run.prefix { $0.timestamp < cutoff })
    }

    // MARK: Stats

    /// Median, not mean — one stray tick must not move the day's anchor.
    static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count.isMultiple(of: 2) ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    static func sd(_ values: [Float]) -> Float {
        guard values.count >= 2 else { return 0 }
        let mean = values.reduce(0, +) / Float(values.count)
        let v = values.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
        return v.squareRoot()
    }
}
