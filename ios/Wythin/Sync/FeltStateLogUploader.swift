import Foundation
import SwiftData

// MARK: - FeltStateUploadPayload
//
// Wire type for POST /felt-state-logs. Same shape as ActivityUploadPayload:
// explicit snake_case CodingKeys, an init(from:) converter. The server side
// (server/routers/felt_state.py) upserts on `id` and keeps a stored value
// when a re-send omits it, so a retry is harmless and an older build's
// narrower payload never clears anything.

struct FeltStateUploadPayload: Codable {
    let id:          String   // FeltStateLog.id → server client_id
    let kind:        String   // "moment" | "previous_day"; a legacy row is a moment
    let timestamp:   String   // ISO8601 — when it was answered
    let dayKey:      String?
    let timezone:    String?
    let focus:       Double?
    let energy:      Double?
    let stress:      Double?
    let mood:        Double?
    let anxiety:     Double?
    let sleep:       Double?
    let stateKey:    String?
    let wornMinutes: Double?

    enum CodingKeys: String, CodingKey {
        case id, kind, timestamp, timezone
        case dayKey = "day_key"
        case focus, energy, stress, mood, anxiety, sleep
        case stateKey = "state_key"
        case wornMinutes = "worn_minutes"
    }

    init(from log: FeltStateLog) {
        let iso    = ISO8601DateFormatter()
        id         = log.id.uuidString
        kind       = log.kind ?? CheckInKind.moment.wireValue
        timestamp  = iso.string(from: log.timestamp)
        dayKey     = log.dayKey
        timezone   = log.timezone
        focus      = log.focus
        energy     = log.energy
        stress     = log.stress
        mood       = log.mood
        anxiety    = log.anxiety
        sleep      = log.sleep
        stateKey   = log.stateKey
        wornMinutes = log.wornMinutes
    }
}

// MARK: - FeltStateLogUploader

/// Uploads saved check-ins to the server, mirroring `ActivityUploader`: a
/// UserDefaults watermark (the last uploaded `timestamp`) so a re-run only
/// sends what's new. Flushed once at launch and again right after every
/// save, so an answer normally reaches the server within a second of being
/// given.
///
/// Main-actor isolated for the same reason as `ActivityUploader`: it operates
/// on the caller's `ModelContext`, which belongs to the main actor.
@MainActor
final class FeltStateLogUploader {

    private let client: FeltStateAPIClient
    private let userID: String
    private let watermarkKey = "feltStateLogs.lastUploadedTimestamp"

    init(client: FeltStateAPIClient, userID: String) {
        self.client = client
        self.userID = userID
    }

    func flushPending(context: ModelContext) async {
        let since = (UserDefaults.standard.object(forKey: watermarkKey) as? Date) ?? .distantPast

        let descriptor = FetchDescriptor<FeltStateLog>(sortBy: [SortDescriptor(\.timestamp)])
        guard let all = try? context.fetch(descriptor) else { return }
        let pending = all.filter { $0.timestamp > since }
        guard !pending.isEmpty else { return }

        var maxTimestamp = since
        for entry in pending {
            do {
                try await client.uploadFeltStateLog(FeltStateUploadPayload(from: entry), userID: userID)
                if entry.timestamp > maxTimestamp { maxTimestamp = entry.timestamp }
            } catch {
                // Stop before advancing past the failure so it retries next flush.
                break
            }
        }
        if maxTimestamp > since {
            UserDefaults.standard.set(maxTimestamp, forKey: watermarkKey)
        }
    }
}
