import Foundation

/// What one measured night looks like on the wire, for the `sleep` mode of
/// `POST /insights`.
///
/// Only derived numbers leave the device — the same ones already printed on the
/// night screen. No raw samples, no timestamps beyond a wall-clock hour and
/// minute, and nothing the person cannot see for themselves two inches above
/// the read.

struct SleepStagePayload: Codable, Equatable {
    let wake: Int?
    let rem:  Int?
    let n1:   Int?
    let n2:   Int?
    let n3:   Int?
}

struct SleepPositionSharePayload: Codable, Equatable {
    let position: String
    let minutes:  Int
}

/// One measure's first half against its second half.
///
/// A night average is a single number for eight hours and hides the only thing
/// worth acting on: whether recovery arrived, and when. The average travels
/// too, as context, but the halves are what the read is built from.
struct SleepArcPayload: Codable, Equatable {
    let firstHalf:  Double?
    let secondHalf: Double?
    let nightAvg:   Double?

    enum CodingKeys: String, CodingKey {
        case firstHalf  = "first_half"
        case secondHalf = "second_half"
        case nightAvg   = "night_avg"
    }
}

struct SleepNightPayload: Codable, Equatable {
    let bedtime:        String?
    let wakeTime:       String?
    let inBedMin:       Int?
    let asleepMin:      Int?
    let score:          Int?
    let sectionScores:  [String: Int]?
    let stages:         SleepStagePayload?
    let wakeBouts:      Int?
    let longestWakeMin: Int?
    let regularity:     Double?
    /// False means the strap stored no orientation on this night — NOT that the
    /// person never lay on their back. The server states the distinction out
    /// loud rather than letting an omission imply the second.
    let positionRecorded: Bool
    let positions:      [SleepPositionSharePayload]?
    let arcs:           [String: SleepArcPayload]?
    let breathBPM:      Double?
    let lowestHR:       Double?
    let lowestHRAt:     String?

    enum CodingKeys: String, CodingKey {
        case bedtime, score, stages, regularity, positions, arcs
        case wakeTime         = "wake_time"
        case inBedMin         = "in_bed_min"
        case asleepMin        = "asleep_min"
        case sectionScores    = "section_scores"
        case wakeBouts        = "wake_bouts"
        case longestWakeMin   = "longest_wake_min"
        case positionRecorded = "position_recorded"
        case breathBPM        = "breath_bpm"
        case lowestHR         = "lowest_hr"
        case lowestHRAt       = "lowest_hr_at"
    }
}

struct SleepInsightPayload: Codable, Equatable {
    let mode: String            // always "sleep"
    let sleep: SleepNightPayload
}

// MARK: - Building one from a night

extension SleepInsightPayload {

    /// Nil when there is no night to read.
    ///
    /// A window with no measured sleep is not a thin night, it is an absent
    /// one, and asking a model to interpret it produces a confident paragraph
    /// about nothing. The server refuses the same case; refusing here too saves
    /// the round trip.
    init?(entry: ActivityLog, night: PreparedNight) {
        guard let end = entry.endedAt else { return nil }

        let asleep = entry.sleepAsleepMinutes ?? SleepStageDetail.allCases
            .filter(\.isAsleep)
            .reduce(0) { $0 + (night.stageMinutes[$1] ?? 0) }
        guard asleep > 0 else { return nil }

        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"

        let wakeBands = night.wakeBands
        let longestWake = wakeBands
            .map { Int(($0.end.timeIntervalSince($0.start) / 60).rounded()) }
            .max()

        // Positions longest-first: the read leads with whichever dominated the
        // night, and supine is the one with an action attached to it.
        let positions = night.positionMinutes
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { SleepPositionSharePayload(position: $0.key.label, minutes: $0.value) }

        let pulse = Self.pulseLow(night)

        self.mode = "sleep"
        self.sleep = SleepNightPayload(
            bedtime:        clock.string(from: entry.startedAt),
            wakeTime:       clock.string(from: end),
            inBedMin:       Int(end.timeIntervalSince(entry.startedAt) / 60),
            asleepMin:      asleep,
            score:          entry.sleepScore,
            sectionScores:  Self.sectionScores(entry),
            stages: SleepStagePayload(
                wake: night.stageMinutes[.wake],
                rem:  night.stageMinutes[.rem],
                n1:   night.stageMinutes[.n1],
                n2:   night.stageMinutes[.n2],
                n3:   night.stageMinutes[.n3]),
            wakeBouts:      wakeBands.count,
            longestWakeMin: longestWake,
            regularity:     entry.sleepRegularity.map(Double.init),
            positionRecorded: night.positionTicks > 0,
            positions:      positions.isEmpty ? nil : positions,
            arcs:           Self.arcs(night),
            breathBPM:      Self.meanBreathRate(night),
            lowestHR:       pulse?.value,
            lowestHRAt:     pulse.map { clock.string(from: $0.date) })
    }

    private static func sectionScores(_ entry: ActivityLog) -> [String: Int]? {
        let pairs: [(SleepSection, Int?)] = [
            (.timing, entry.sleepTiming), (.duration, entry.sleepDuration),
            (.continuity, entry.sleepContinuity), (.autonomic, entry.sleepAutonomic),
            (.breathing, entry.sleepBreathing),
        ]
        // A section with no input has not been measured. Sending it as 0 would
        // hand the model a verdict the app itself refuses to print.
        let present = pairs.compactMap { section, value in value.map { (section.name, $0) } }
        return present.isEmpty ? nil : Dictionary(uniqueKeysWithValues: present)
    }

    /// Each charted measure's two halves, keyed by the wire name the server
    /// knows it under.
    ///
    /// `LiveMetric`'s raw value IS that name — it is what the Track macro read
    /// already sends — so the key comes from the metric itself rather than
    /// from a second table that could drift away from the first.
    private static func arcs(_ night: PreparedNight) -> [String: SleepArcPayload]? {
        var out: [String: SleepArcPayload] = [:]
        for def in activityMetricDefs {
            let samples = night.series[def.id] ?? []
            guard samples.count >= 2 else { continue }
            let mid = samples.count / 2
            let first  = mean(samples.prefix(mid).map(\.value))
            let second = mean(samples.suffix(from: mid).map(\.value))
            guard first != nil || second != nil else { continue }
            out[def.metric.rawValue] = SleepArcPayload(
                firstHalf: first, secondHalf: second, nightAvg: night.averages[def.id])
        }
        return out.isEmpty ? nil : out
    }

    /// The night's low point in Pulse, off the bucketed line rather than the
    /// raw ticks: a single tick's minimum is one noisy beat window, and the
    /// question being asked ("when did the body actually bottom out") is about
    /// a stretch of the night, not an instant.
    private static func pulseLow(_ night: PreparedNight) -> PreparedNight.Sample? {
        let pulse = metricDef(.hr)
        return (night.series[pulse.id] ?? []).min { $0.value < $1.value }
    }

    private static func meanBreathRate(_ night: PreparedNight) -> Double? {
        mean(night.points.compactMap { $0.breathBPM.map(Double.init) })
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
