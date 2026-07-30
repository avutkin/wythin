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

    enum CodingKeys: String, CodingKey {
        case id
        case activityType    = "activity_type"
        case activitySubtype = "activity_subtype"
        case customName      = "custom_name"
        case startedAt       = "started_at"
        case endedAt         = "ended_at"
        case isManual        = "is_manual"
        case impactDeltaPct  = "impact_delta_pct"
        case notes
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
    private let watermarkKey = "activities.lastUploadedEndedAt"

    init(client: APIClient, userID: String) {
        self.client = client
        self.userID = userID
    }

    func flushPending(context: ModelContext) async {
        let since = (UserDefaults.standard.object(forKey: watermarkKey) as? Date) ?? .distantPast

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
            UserDefaults.standard.set(maxEnded, forKey: watermarkKey)
        }
    }
}
