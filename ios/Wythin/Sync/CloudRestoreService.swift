import Foundation
import SwiftData
import UIKit

/// One-shot recovery of this user's cloud copy back into the local store.
///
/// Exists because upload used to be the only direction: a phone whose store
/// was gone (wiped, reinstalled, migrated) had months of samples on the server
/// and no way to read them back. Pages `/v1/metrics/export` oldest-first,
/// re-inserts anything the store doesn't already hold, then does the same for
/// activities — so running it twice, or over a half-full store, only fills
/// gaps and never duplicates.
@MainActor
@Observable
final class CloudRestoreService {

    enum Phase: Equatable {
        case idle
        case restoring(samples: Int)
        case done(samples: Int, activities: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    var isRunning: Bool {
        if case .restoring = phase { return true }
        return false
    }

    /// Cursor of the last fully-imported page, persisted so an interrupted
    /// restore (backgrounding kills the in-flight request — the first real
    /// attempt died exactly that way) resumes where it stopped instead of
    /// re-fetching from 1970.
    static let cursorKey = "cloudRestoreCursor"

    func run(env: AppEnvironment, context: ModelContext) async {
        guard !isRunning else { return }
        phase = .restoring(samples: 0)

        let client    = env.sync.client
        let userID    = env.userID
        let container = env.modelContainer
        var samplesImported = 0

        // Buys ~30 s of survival if the user leaves the app mid-restore; the
        // cursor makes anything beyond that resumable rather than fatal.
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "cloud-restore")
        defer {
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
        }

        do {
            var cursor: String? = UserDefaults.standard.string(forKey: Self.cursorKey)
            repeat {
                let page = try await client.exportMetrics(cursor: cursor, userID: userID)
                guard !page.samples.isEmpty else { break }
                // Insert on a background context — 5000 @Model inserts per
                // page on the main actor froze the UI for the whole restore.
                let samples = page.samples
                samplesImported += try await Task.detached {
                    let ctx = ModelContext(container)
                    let n = CloudRestoreService.insert(samples, into: ctx)
                    try ctx.save()
                    return n
                }.value
                phase  = .restoring(samples: samplesImported)
                cursor = page.next_cursor
                if let done = cursor {
                    UserDefaults.standard.set(done, forKey: Self.cursorKey)
                }
            } while cursor != nil

            let payloads = try await client.fetchActivities(userID: userID)
            let activitiesImported = try await Task.detached {
                let ctx = ModelContext(container)
                let n = CloudRestoreService.insert(payloads, into: ctx)
                try ctx.save()
                return n
            }.value

            // Samples and windows are back, but everything DERIVED from them —
            // zones, heart-rate recovery, the exercise indices — is not stored
            // server-side, and the launch backfill skips entries whose windows
            // are already filled. Recompute here, where the restored samples
            // exist to compute from. Only entries with samples in their span:
            // recomputing an activity whose samples never uploaded would wipe
            // the server-provided windows with nils.
            try await Task.detached {
                let ctx = ModelContext(container)
                let logs = try ctx.fetch(FetchDescriptor<ActivityLog>())
                for entry in logs where entry.endedAt != nil {
                    let start = entry.startedAt, end = entry.endedAt!
                    let inSpan = FetchDescriptor<HRVSample>(
                        predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end })
                    guard ((try? ctx.fetchCount(inSpan)) ?? 0) > 0 else { continue }
                    entry.computeHRVWindows(context: ctx)
                    entry.computeExerciseResponse(context: ctx)
                }
                try ctx.save()
            }.value

            UserDefaults.standard.removeObject(forKey: Self.cursorKey)
            // Tonight's launch warm-up may have branded the restored days
            // "no data" — a sticky negative verdict — so derived caches must
            // be rebuilt from the store, not trusted.
            env.rewarmAfterRestore()
            phase = .done(samples: samplesImported, activities: activitiesImported)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Pure import steps (unit-tested against an in-memory store)

    /// Inserts every sample the store doesn't already hold at that exact
    /// timestamp; returns how many were new.
    nonisolated static func insert(_ samples: [MetricExportSample],
                                   into context: ModelContext) -> Int {
        let dated: [(Date, MetricExportSample)] = samples.compactMap { s in
            date(s.ts).map { ($0, s) }
        }
        guard let first = dated.first?.0, let last = dated.last?.0 else { return 0 }

        let desc = FetchDescriptor<HRVSample>(
            predicate: #Predicate { $0.timestamp >= first && $0.timestamp <= last })
        let existing = Set(((try? context.fetch(desc)) ?? []).map(\.timestamp))

        var inserted = 0
        for (ts, s) in dated where !existing.contains(ts) {
            context.insert(HRVSample(
                cloudTs: ts,
                meanBPM: s.mean_bpm, rmssd: s.rmssd, sdnn: s.sdnn, pnn50: s.pnn50,
                lfHF: s.lf_hf, rsaMs: s.rsa_ms, coherence: s.coherence, cbi: s.cbi,
                breathBPM: s.breath_bpm, dfa1: s.dfa1, rcmse: s.rcmse, pip: s.pip,
                dc: s.dc, vti: s.vti))
            inserted += 1
        }
        return inserted
    }

    /// Recreates activities the store doesn't already hold (matched by the
    /// UUID the phone originally assigned); returns how many were new.
    nonisolated static func insert(_ payloads: [ActivityUploadPayload],
                                   into context: ModelContext) -> Int {
        let existing = Set(((try? context.fetch(FetchDescriptor<ActivityLog>())) ?? []).map(\.id))

        var inserted = 0
        for p in payloads {
            guard let id = UUID(uuidString: p.id), !existing.contains(id),
                  let started = date(p.startedAt) else { continue }
            let ended = p.endedAt.flatMap(date)
            // An unended, non-manual row would come back as "recording now"
            // and pin a live banner to a session that ended weeks ago.
            guard ended != nil || p.isManual else { continue }

            let log = ActivityLog(activityType: p.activityType,
                                  activitySubtype: p.activitySubtype,
                                  customName: p.customName,
                                  startedAt: started,
                                  endedAt: ended,
                                  isManual: p.isManual)
            log.id    = id
            log.notes = p.notes
            log.beforeHR    = p.beforeHR;    log.duringHR    = p.duringHR;    log.afterHR    = p.afterHR
            log.beforeRMSSD = p.beforeRMSSD; log.duringRMSSD = p.duringRMSSD; log.afterRMSSD = p.afterRMSSD
            log.beforeSDNN  = p.beforeSDNN;  log.duringSDNN  = p.duringSDNN;  log.afterSDNN  = p.afterSDNN
            log.beforeRSA   = p.beforeRSA;   log.duringRSA   = p.duringRSA;   log.afterRSA   = p.afterRSA
            log.beforeVTI   = p.beforeVTI;   log.duringVTI   = p.duringVTI;   log.afterVTI   = p.afterVTI
            log.beforeLFHF  = p.beforeLFHF;  log.duringLFHF  = p.duringLFHF;  log.afterLFHF  = p.afterLFHF
            log.beforeStress = p.beforeStress; log.duringStress = p.duringStress; log.afterStress = p.afterStress
            log.beforeRCMSE = p.beforeRCMSE; log.duringRCMSE = p.duringRCMSE; log.afterRCMSE = p.afterRCMSE
            log.beforePIP   = p.beforePIP;   log.duringPIP   = p.duringPIP;   log.afterPIP   = p.afterPIP
            log.beforeDC    = p.beforeDC;    log.duringDC    = p.duringDC;    log.afterDC    = p.afterDC
            log.beforeDFA1  = p.beforeDFA1;  log.duringDFA1  = p.duringDFA1;  log.afterDFA1  = p.afterDFA1
            context.insert(log)
            inserted += 1
        }
        return inserted
    }

    /// Server timestamps arrive as ISO 8601 with a numeric offset, with or
    /// without fractional seconds ("2026-07-27T10:00:00+00:00",
    /// "…10:00:00.123456+00:00"); uploads used "Z". Accept all three.
    nonisolated static func date(_ s: String) -> Date? {
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
}
