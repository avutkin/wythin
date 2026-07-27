import Foundation

// MARK: - Thresholds

/// Every gate the day's rested anchor must clear. One place, so the
/// stillness threshold can be calibrated against real captures.
enum AnchorThresholds {
    /// ACC magnitude SD (mg) below which the window counts as still.
    static let stillnessSD: Float = 20
    /// Fallback when `motion` is absent (backfilled history): SD of HR, bpm.
    static let hrStabilitySD: Float = 3
    static let minSignalQuality: Float = 0.9
    static let maxInvalidRate: Float = 0.05
    static let minECGTier: Int = 1
    static let breathRange: ClosedRange<Float> = 8...20
    /// Preferred window length — below this DC is dropped from the score.
    static let preferredMinSec: Double = 300
    /// Absolute minimum window length.
    static let minSec: Double = 180
    /// Windows starting before this hour are preferred over later ones.
    static let morningCutoffHour: Int = 12
    /// Largest gap between consecutive ticks still counted as continuous.
    static let maxGapSec: Double = 6
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
        let usable = points
            .filter { passesPointGates($0) }
            .sorted { $0.timestamp < $1.timestamp }
        guard !usable.isEmpty else { return nil }

        let runs = continuousRuns(usable).filter { run in
            duration(run) >= AnchorThresholds.minSec && passesRunGates(run)
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
        guard let q = p.signalQuality, q >= AnchorThresholds.minSignalQuality else { return false }
        guard let inv = p.rrInvalidRate, inv <= AnchorThresholds.maxInvalidRate else { return false }
        guard let tier = p.ecgQualityTier, tier >= AnchorThresholds.minECGTier else { return false }
        guard p.vti != nil, p.meanBPM != nil else { return false }
        if let m = p.motion, m > AnchorThresholds.stillnessSD { return false }
        if let b = p.breathBPM, !AnchorThresholds.breathRange.contains(b) { return false }
        return true
    }

    /// When motion is unknown for the whole run, fall back to HR stability.
    private static func passesRunGates(_ run: [MetricsHistoryPoint]) -> Bool {
        let motionKnown = run.contains { $0.motion != nil }
        guard !motionKnown else { return true }
        let hrs = run.compactMap { $0.meanBPM }
        guard hrs.count >= 2 else { return false }
        return sd(hrs) <= AnchorThresholds.hrStabilitySD
    }

    // MARK: Assembly

    private static func continuousRuns(_ points: [MetricsHistoryPoint]) -> [[MetricsHistoryPoint]] {
        var runs: [[MetricsHistoryPoint]] = []
        var current: [MetricsHistoryPoint] = []
        for p in points {
            if let last = current.last,
               p.timestamp.timeIntervalSince(last.timestamp) > AnchorThresholds.maxGapSec {
                runs.append(current)
                current = []
            }
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
        guard let lnRMSSD = median(run.compactMap { $0.vti }),
              let restingHR = median(run.compactMap { $0.meanBPM }),
              let start = run.first?.timestamp else { return nil }

        let dur = duration(run)
        // DC is a phase-rectified statistic — it needs the longer window to be
        // stable, so a short anchor drops it rather than reporting it noisily.
        let longEnoughForDC = dur >= AnchorThresholds.preferredMinSec
        let motionKnown = run.contains { $0.motion != nil }

        let cal = Calendar.current
        let hour = Double(cal.component(.hour, from: start))
                 + Double(cal.component(.minute, from: start)) / 60

        let confidence: AnchorConfidence
        if !motionKnown                  { confidence = .low }
        else if longEnoughForDC && !late { confidence = .high }
        else                             { confidence = .medium }

        return AnchorReading(
            startedAt:   start,
            durationSec: dur,
            hour:        hour,
            lnRMSSD:     lnRMSSD,
            dc:          longEnoughForDC ? median(run.compactMap { $0.dc }) : nil,
            restingHR:   restingHR,
            pip:         median(run.compactMap { $0.pip }),
            dfa1:        median(run.compactMap { $0.dfa1 }),
            breathBPM:   median(run.compactMap { $0.breathBPM }),
            late:        late,
            motionKnown: motionKnown,
            confidence:  confidence)
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
