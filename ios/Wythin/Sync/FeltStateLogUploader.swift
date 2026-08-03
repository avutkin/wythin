import Foundation
import SwiftData

// MARK: - FeltStateUploadPayload
//
// Wire type for POST /felt-state-logs. Same shape as ActivityUploadPayload:
// explicit snake_case CodingKeys, an init(from:) converter. The server
// endpoint and table for this are not part of this change — this is only the
// client half of the same pattern every other synced model uses, so a check-
// in already rides the existing upload mechanism the moment the server side
// exists.

struct FeltStateUploadPayload: Codable {
    let id:        String   // FeltStateLog.id → server client_felt_state_id
    let timestamp: String   // ISO8601
    let focus:     Double?
    let energy:    Double?
    let stress:    Double?
    let mood:      Double?
    let stateKey:  String?

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case focus, energy, stress, mood
        case stateKey = "state_key"
    }

    init(from log: FeltStateLog) {
        let iso   = ISO8601DateFormatter()
        id        = log.id.uuidString
        timestamp = iso.string(from: log.timestamp)
        focus     = log.focus
        energy    = log.energy
        stress    = log.stress
        mood      = log.mood
        stateKey  = log.stateKey
    }
}

// MARK: - FeltStateLogUploader

/// Uploads saved check-ins to the server, mirroring `ActivityUploader`: a
/// UserDefaults watermark (the last uploaded `timestamp`) so a re-run only
/// sends what's new, and no local schema change if a later build adds
/// fields — the server is expected to upsert on the client id the same way
/// activities do, so a re-send is harmless.
///
/// Main-actor isolated for the same reason as `ActivityUploader`: it operates
/// on the caller's `ModelContext`, which belongs to the main actor.
@MainActor
final class FeltStateLogUploader {

    private let client: APIClient
    private let userID: String
    private let watermarkKey = "feltStateLogs.lastUploadedTimestamp"

    init(client: APIClient, userID: String) {
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
