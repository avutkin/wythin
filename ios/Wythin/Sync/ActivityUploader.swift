import Foundation
import SwiftData

// MARK: - ActivityUploadPayload
//
// Wire type for POST /activities. Explicit CodingKeys map to the server's
// snake_case columns exactly (no reliance on key-conversion). Metric fields are
// ActivityLog's stored before/during/after window averages.

struct ActivityUploadPayload: Codable {
    let id:              String   // ActivityLog.id → server client_activity_id
    let activityType:    String
    let activitySubtype: String?
    let customName:      String?
    let startedAt:       String   // ISO8601
    let endedAt:         String?
    let isManual:        Bool
    let impactDeltaPct:  Float?
    let notes:           String?
    /// The night, for a `Sleep` row; nil for everything else.
    let sleep:           SleepUploadPayload?
    /// The phone's IANA zone as this row goes up — the clock the activity
    /// happened in, so a night recorded on a trip keeps its own hours.
    /// Optional on the way back down: rows uploaded before the app sent a
    /// zone come back from the server with none, and restore must still decode them.
    let timezone:        String?

    let beforeHR: Float?;     let duringHR: Float?;     let afterHR: Float?
    let beforeRMSSD: Float?;  let duringRMSSD: Float?;  let afterRMSSD: Float?
    let beforeSDNN: Float?;   let duringSDNN: Float?;   let afterSDNN: Float?
    let beforeRSA: Float?;    let duringRSA: Float?;    let afterRSA: Float?
    let beforeVTI: Float?;    let duringVTI: Float?;    let afterVTI: Float?
    let beforeLFHF: Float?;   let duringLFHF: Float?;   let afterLFHF: Float?
    let beforeStress: Float?; let duringStress: Float?; let afterStress: Float?
    let beforeRCMSE: Float?;  let duringRCMSE: Float?;  let afterRCMSE: Float?
    let beforePIP: Float?;    let duringPIP: Float?;    let afterPIP: Float?
    let beforeDC: Float?;     let duringDC: Float?;     let afterDC: Float?
    let beforeDFA1: Float?;   let duringDFA1: Float?;   let afterDFA1: Float?
    let beforeBreath: Float?; let duringBreath: Float?; let afterBreath: Float?

    enum CodingKeys: String, CodingKey {
        case id
        case activityType    = "activity_type"
        case activitySubtype = "activity_subtype"
        case customName      = "custom_name"
        case startedAt       = "started_at"
        case endedAt         = "ended_at"
        case isManual        = "is_manual"
        case impactDeltaPct  = "impact_delta_pct"
        case notes, sleep, timezone
        case beforeHR = "before_hr",         duringHR = "during_hr",         afterHR = "after_hr"
        case beforeRMSSD = "before_rmssd",   duringRMSSD = "during_rmssd",   afterRMSSD = "after_rmssd"
        case beforeSDNN = "before_sdnn",     duringSDNN = "during_sdnn",     afterSDNN = "after_sdnn"
        case beforeRSA = "before_rsa",       duringRSA = "during_rsa",       afterRSA = "after_rsa"
        case beforeVTI = "before_vti",       duringVTI = "during_vti",       afterVTI = "after_vti"
        case beforeLFHF = "before_lfhf",     duringLFHF = "during_lfhf",     afterLFHF = "after_lfhf"
        case beforeStress = "before_stress", duringStress = "during_stress", afterStress = "after_stress"
        case beforeRCMSE = "before_rcmse",   duringRCMSE = "during_rcmse",   afterRCMSE = "after_rcmse"
        case beforePIP = "before_pip",       duringPIP = "during_pip",       afterPIP = "after_pip"
        case beforeDC = "before_dc",         duringDC = "during_dc",         afterDC = "after_dc"
        case beforeDFA1 = "before_dfa1",     duringDFA1 = "during_dfa1",     afterDFA1 = "after_dfa1"
        case beforeBreath = "before_breath", duringBreath = "during_breath", afterBreath = "after_breath"
    }

    init(from e: ActivityLog) {
        let iso = ISO8601DateFormatter()
        id              = e.id.uuidString
        activityType    = e.activityType
        activitySubtype = e.activitySubtype
        customName      = e.customName
        startedAt       = iso.string(from: e.startedAt)
        endedAt         = e.endedAt.map { iso.string(from: $0) }
        isManual        = e.isManual
        impactDeltaPct  = e.impactDeltaPct.map(Float.init)
        notes           = e.notes
        sleep           = SleepUploadPayload(from: e)
        timezone        = TimeZone.current.identifier
        beforeHR = e.beforeHR;         duringHR = e.duringHR;         afterHR = e.afterHR
        beforeRMSSD = e.beforeRMSSD;   duringRMSSD = e.duringRMSSD;   afterRMSSD = e.afterRMSSD
        beforeSDNN = e.beforeSDNN;     duringSDNN = e.duringSDNN;     afterSDNN = e.afterSDNN
        beforeRSA = e.beforeRSA;       duringRSA = e.duringRSA;       afterRSA = e.afterRSA
        beforeVTI = e.beforeVTI;       duringVTI = e.duringVTI;       afterVTI = e.afterVTI
        beforeLFHF = e.beforeLFHF;     duringLFHF = e.duringLFHF;     afterLFHF = e.afterLFHF
        beforeStress = e.beforeStress; duringStress = e.duringStress; afterStress = e.afterStress
        beforeRCMSE = e.beforeRCMSE;   duringRCMSE = e.duringRCMSE;   afterRCMSE = e.afterRCMSE
        beforePIP = e.beforePIP;       duringPIP = e.duringPIP;       afterPIP = e.afterPIP
        beforeDC = e.beforeDC;         duringDC = e.duringDC;         afterDC = e.afterDC
        beforeDFA1 = e.beforeDFA1;     duringDFA1 = e.duringDFA1;     afterDFA1 = e.afterDFA1
        beforeBreath = e.beforeBreath; duringBreath = e.duringBreath; afterBreath = e.afterBreath
    }
}

// MARK: - SleepUploadPayload

/// A recorded night on the wire, inside the activity upload.
///
/// The row's own sleep columns plus `SleepNightDetail`, flattened into one
/// object under the insight payload's names. Absent sections stay absent —
/// "not measured" and "scored 0" are different sentences, and the server
/// stores this as uploaded.
struct SleepUploadPayload: Codable {
    struct Sections: Codable {
        let timing: Int?; let duration: Int?; let continuity: Int?
        let autonomic: Int?; let breathing: Int?
    }
    struct Stages: Codable {
        let wake: Int?; let rem: Int?; let n1: Int?; let n2: Int?; let n3: Int?
    }

    let score:            Int?
    let arithmetic:       String?
    let stageSummary:     String?
    let asleepMin:        Int?
    let inBedMin:         Int?
    /// Circular SD of sleep onset, in minutes. Lower is steadier. Replaced
    /// the Sleep Regularity Index, which a few nights of wear cannot measure.
    let bedtimeSDMin:     Double?
    let algorithmVersion: Int?
    let readText:         String?
    let sections:         Sections
    let stages:           Stages
    /// What each section was made of — label, value, the range it was read
    /// against, its score and its share — keyed by section. The night screen
    /// shows these instead of describing the section; the dashboard can too.
    let parts:            [String: [SleepScore.Part]]?
    /// Vagal tone inside quiet sleep, stored so the next night's baseline
    /// survives a restore.
    let quietRMSSD:       Float?
    let quietDC:          Float?

    let wakeBouts:          Int?
    let longestUnbrokenMin: Int?
    let longestWakeMin:     Int?
    let lowestHR:           Double?
    let lowestHRAt:         String?
    let positionRecorded:   Bool?
    let positions:          [SleepNightDetail.PositionShare]?
    let positionBands:      [SleepNightDetail.PositionBand]?
    let stageRuns:          [SleepNightDetail.Run]?

    /// The pair that makes a night a labelled example: what the detector
    /// proposed, and the fact that the sleeper moved it. Both nil for a night
    /// nobody corrected — which is most of them, and is itself informative.
    ///
    /// The corrected boundaries are already the row's `started_at`/`ended_at`,
    /// because the app rebuilds a corrected night and re-uploads it. Only the
    /// detector's original answer was being thrown away, and without it the
    /// error is unmeasurable.
    let detectedStart: String?
    let detectedEnd:   String?
    let correctedAt:   String?

    enum CodingKeys: String, CodingKey {
        case score, arithmetic, sections, stages, positions, parts
        case quietRMSSD         = "quiet_rmssd"
        case quietDC            = "quiet_dc"
        case bedtimeSDMin       = "bedtime_sd_min"
        case stageSummary       = "stage_summary"
        case asleepMin          = "asleep_min"
        case inBedMin           = "in_bed_min"
        case algorithmVersion   = "algorithm_version"
        case readText           = "read_text"
        case wakeBouts          = "wake_bouts"
        case longestUnbrokenMin = "longest_unbroken_min"
        case longestWakeMin     = "longest_wake_min"
        case detectedStart      = "detected_start"
        case detectedEnd        = "detected_end"
        case correctedAt        = "corrected_at"
        case lowestHR           = "lowest_hr"
        case lowestHRAt         = "lowest_hr_at"
        case positionRecorded   = "position_recorded"
        case positionBands      = "position_bands"
        case stageRuns          = "stage_runs"
    }

    /// Nil unless the entry is a night.
    init?(from e: ActivityLog) {
        guard e.activityType == ActivityType.sleep.rawValue else { return nil }
        let detail = SleepNightDetail(json: e.sleepDetailJSON)
        score            = e.sleepScore
        arithmetic       = e.sleepScoreArithmetic
        stageSummary     = e.sleepStageSummary
        asleepMin        = e.sleepAsleepMinutes
        inBedMin         = e.endedAt.map { Int($0.timeIntervalSince(e.startedAt) / 60) }
        bedtimeSDMin     = e.sleepBedtimeSDMin
        algorithmVersion = e.sleepAlgorithmVersion
        readText         = e.sleepReadText
        sections = Sections(timing: e.sleepTiming, duration: e.sleepDuration,
                            continuity: e.sleepContinuity, autonomic: e.sleepAutonomic,
                            breathing: e.sleepBreathing)
        stages = Stages(wake: e.sleepAwakeMinutes, rem: e.sleepREMMinutes, n1: e.sleepN1Minutes,
                        n2: e.sleepLightMinutes, n3: e.sleepDeepMinutes)
        let stored = SleepScore.parts(fromJSON: e.sleepPartsJSON)
        parts = stored.isEmpty ? nil
            : Dictionary(uniqueKeysWithValues: stored.map { ($0.key.rawValue, $0.value) })
        quietRMSSD = e.sleepQuietRMSSD
        quietDC    = e.sleepQuietDC
        let iso = ISO8601DateFormatter()
        detectedStart = e.sleepDetectedStart.map { iso.string(from: $0) }
        detectedEnd   = e.sleepDetectedEnd.map { iso.string(from: $0) }
        correctedAt   = e.sleepCorrectedAt.map { iso.string(from: $0) }
        wakeBouts          = detail?.wakeBouts
        longestUnbrokenMin = detail?.longestUnbrokenMin
        longestWakeMin     = detail?.longestWakeMin
        lowestHR           = detail?.lowestHR
        lowestHRAt         = detail?.lowestHRAt
        positionRecorded   = detail?.positionRecorded
        positions          = detail?.positions
        positionBands      = detail?.positionBands
        stageRuns          = detail?.stageRuns
    }

    /// The row's fields, back from the wire — for a restore into an empty
    /// store. The detail goes back as the JSON it came from.
    func apply(to e: ActivityLog) {
        e.sleepScore           = score
        e.sleepScoreArithmetic = arithmetic
        e.sleepStageSummary    = stageSummary
        e.sleepAsleepMinutes   = asleepMin
        e.sleepBedtimeSDMin    = bedtimeSDMin
        e.sleepAlgorithmVersion = algorithmVersion
        e.sleepReadText        = readText
        e.sleepTiming = sections.timing; e.sleepDuration = sections.duration
        e.sleepContinuity = sections.continuity; e.sleepAutonomic = sections.autonomic
        e.sleepBreathing = sections.breathing
        e.sleepAwakeMinutes = stages.wake; e.sleepREMMinutes = stages.rem; e.sleepN1Minutes = stages.n1
        e.sleepLightMinutes = stages.n2;   e.sleepDeepMinutes = stages.n3
        if let parts {
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
            e.sleepPartsJSON = (try? enc.encode(parts)).flatMap { String(data: $0, encoding: .utf8) }
        }
        e.sleepQuietRMSSD = quietRMSSD
        e.sleepQuietDC    = quietDC
        if let wakeBouts, let longestUnbrokenMin, let longestWakeMin, let positionRecorded {
            let detail = SleepNightDetail(
                wakeBouts: wakeBouts, longestUnbrokenMin: longestUnbrokenMin,
                longestWakeMin: longestWakeMin, lowestHR: lowestHR, lowestHRAt: lowestHRAt,
                positionRecorded: positionRecorded, positions: positions ?? [],
                positionBands: positionBands ?? [], stageRuns: stageRuns ?? [])
            e.sleepDetailJSON = detail.json
        }
    }
}

// MARK: - ActivityUploadWatermark

/// The uploader's "everything that ended before this has been sent" mark.
///
/// Its own type, not on the actor: the sleep recorder needs to move it from a
/// background context, and `UserDefaults` is safe to touch from anywhere.
enum ActivityUploadWatermark {
    static let key = "activities.lastUploadedEndedAt"

    static var value: Date {
        (UserDefaults.standard.object(forKey: key) as? Date) ?? .distantPast
    }

    static func advance(to date: Date) {
        UserDefaults.standard.set(date, forKey: key)
    }

    /// Pull the mark back so a row that ended at `date` is sent again. A
    /// no-op when the mark is already behind it.
    static func rewind(before date: Date) {
        let moved = date.addingTimeInterval(-1)
        guard moved < value else { return }
        UserDefaults.standard.set(moved, forKey: key)
    }
}

// MARK: - ActivityUploader

/// Uploads finished ActivityLog records to the server. No local schema change:
/// a UserDefaults watermark (last uploaded `endedAt`) avoids re-uploading, while
/// the server upserts on client_activity_id so any re-send is harmless — including
/// re-sends from this build, which omits `impact_score` entirely; the server
/// COALESCEs that column on conflict so an absent value never clears a real
/// historical score written by an older build. On the first run the watermark
/// is `.distantPast`, so it backfills existing activities.
/// Main-actor isolated for the same reason as `UsageUploader`: it operates on
/// the caller's `ModelContext`, which is not thread-safe and belongs to the main
/// actor. An `actor` here would do SwiftData work on a background executor.
@MainActor
final class ActivityUploader {

    private let client: APIClient
    private let userID: String

    init(client: APIClient, userID: String) {
        self.client = client
        self.userID = userID
    }

    func flushPending(context: ModelContext) async {
        let since = ActivityUploadWatermark.value

        // Fetch all and filter in Swift — keeps the SwiftData predicate simple
        // and the volume is small (one row per logged activity).
        let descriptor = FetchDescriptor<ActivityLog>(sortBy: [SortDescriptor(\.startedAt)])
        guard let all = try? context.fetch(descriptor) else { return }
        let pending = all
            .filter { ($0.endedAt ?? .distantPast) > since }
            .sorted { ($0.endedAt ?? .distantPast) < ($1.endedAt ?? .distantPast) }
        guard !pending.isEmpty else { return }

        var maxEnded = since
        for entry in pending {
            do {
                _ = try await client.uploadActivity(ActivityUploadPayload(from: entry), userID: userID)
                if let e = entry.endedAt, e > maxEnded { maxEnded = e }
            } catch {
                // Stop before advancing past the failure so it retries next flush.
                break
            }
        }
        if maxEnded > since {
            ActivityUploadWatermark.advance(to: maxEnded)
        }
    }
}
