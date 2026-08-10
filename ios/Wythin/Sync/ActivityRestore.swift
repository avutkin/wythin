import Foundation
import SwiftData

/// Pulls this account's activities back down when the local store has none.
///
/// Upload was the only direction that existed, so a phone that was reinstalled,
/// restored to a new device, or had its store reset came up empty and stayed
/// empty — every session the server still held was unreachable from the app
/// that wrote it.
///
/// Runs only into an **empty** store. It never merges, because the server holds
/// the window averages but not the derived exercise fields, and writing those
/// rows alongside locally-computed ones would produce two populations that look
/// identical and are not. On an empty store there is nothing to disagree with,
/// and the backfill recomputes the derived fields immediately afterwards.
enum ActivityRestore {

    /// Guard so a genuinely new user — empty store, empty server — does not pay
    /// for a network round trip on every launch forever.
    static let attemptedKey = "didAttemptActivityRestore"

    @MainActor
    static func restoreIfEmpty(context: ModelContext,
                               client: APIClient,
                               userID: String) async {
        guard !UserDefaults.standard.bool(forKey: attemptedKey) else { return }

        let existing = (try? context.fetchCount(FetchDescriptor<ActivityLog>())) ?? 0
        guard existing == 0 else {
            // A populated store is the normal case; mark it done so the check
            // costs nothing from here on.
            UserDefaults.standard.set(true, forKey: attemptedKey)
            return
        }

        guard let payloads = try? await client.fetchActivities(userID: userID) else {
            // A failed fetch is not an answer. Leave the flag down so the next
            // launch tries again rather than concluding the account is empty.
            return
        }

        for payload in payloads {
            guard let entry = make(from: payload) else { continue }
            context.insert(entry)
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: attemptedKey)
    }

    /// One server row back into a local entry.
    ///
    /// Only the fields the server actually stores. Everything derived —
    /// the exercise response, the axis scores, readiness — is deliberately left
    /// nil for the backfill to recompute, so a restored session is scored by
    /// this build's arithmetic rather than by whatever produced it originally.
    static func make(from p: ActivityUploadPayload) -> ActivityLog? {
        guard let started = iso(p.startedAt) else { return nil }

        let entry = ActivityLog(activityType: p.activityType,
                                activitySubtype: p.activitySubtype,
                                customName: p.customName,
                                startedAt: started,
                                endedAt: p.endedAt.flatMap(iso),
                                isManual: p.isManual)
        // The server key is the client id it was uploaded with, so a restored
        // row keeps its identity and a later re-upload upserts rather than
        // duplicating.
        if let uuid = UUID(uuidString: p.id) { entry.id = uuid }
        entry.notes = p.notes

        entry.beforeHR = p.beforeHR;         entry.duringHR = p.duringHR;         entry.afterHR = p.afterHR
        entry.beforeRMSSD = p.beforeRMSSD;   entry.duringRMSSD = p.duringRMSSD;   entry.afterRMSSD = p.afterRMSSD
        entry.beforeSDNN = p.beforeSDNN;     entry.duringSDNN = p.duringSDNN;     entry.afterSDNN = p.afterSDNN
        entry.beforeRSA = p.beforeRSA;       entry.duringRSA = p.duringRSA;       entry.afterRSA = p.afterRSA
        entry.beforeVTI = p.beforeVTI;       entry.duringVTI = p.duringVTI;       entry.afterVTI = p.afterVTI
        entry.beforeLFHF = p.beforeLFHF;     entry.duringLFHF = p.duringLFHF;     entry.afterLFHF = p.afterLFHF
        entry.beforeStress = p.beforeStress; entry.duringStress = p.duringStress; entry.afterStress = p.afterStress
        entry.beforeRCMSE = p.beforeRCMSE;   entry.duringRCMSE = p.duringRCMSE;   entry.afterRCMSE = p.afterRCMSE
        entry.beforePIP = p.beforePIP;       entry.duringPIP = p.duringPIP;       entry.afterPIP = p.afterPIP
        entry.beforeDC = p.beforeDC;         entry.duringDC = p.duringDC;         entry.afterDC = p.afterDC
        entry.beforeDFA1 = p.beforeDFA1;     entry.duringDFA1 = p.duringDFA1;     entry.afterDFA1 = p.afterDFA1

        return entry
    }

    /// The server sends ISO8601, with fractional seconds on some rows and not
    /// on others, so both are tried rather than dropping half the history.
    static func iso(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
}
