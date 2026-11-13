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

/// Each answer stays pending until the server acknowledges it and that receipt
/// is saved locally. Legacy timestamp watermarks are deliberately ignored: they
/// cannot prove which rows were actually received. The server upserts by UUID,
/// making the one-time historical replay and retries after a lost receipt safe.
@MainActor
final class FeltStateLogUploader {
    private let client: FeltStateAPIClient
    private let userID: String
    private let defaults: UserDefaults
    private let destination: String
    private(set) var isUploading = false
    private(set) var lastError: String?
    private var flushRequested = false

    init(client: FeltStateAPIClient, userID: String, defaults: UserDefaults = .standard) {
        self.client = client
        self.userID = userID
        self.defaults = defaults
        // Use the actual client's endpoint, not a setting changed before relaunch.
        // The server resolves device IDs as case-sensitive text.
        self.destination = client.baseURL.absoluteString + "|" + userID
    }

    private var isEnabled: Bool {
        defaults.object(forKey: "cloudSyncEnabled") as? Bool ?? true
    }

    func flushPending(context: ModelContext) async {
        guard isEnabled else { return }
        if isUploading {
            flushRequested = true
            return
        }
        isUploading = true
        lastError = nil
        defer { isUploading = false }

        repeat {
            flushRequested = false
            let all: [FeltStateLog]
            do {
                // Never upload or acknowledge an answer that failed local persistence.
                try context.save()
                all = try context.fetch(FetchDescriptor<FeltStateLog>(sortBy: [SortDescriptor(\.timestamp)]))
            } catch {
                lastError = "Could not read saved check-ins. They will be retried."
                return
            }
            for entry in all where entry.uploadedDestination != destination {
                guard isEnabled, !Task.isCancelled else { return }
                do {
                    try await client.uploadFeltStateLog(FeltStateUploadPayload(from: entry), userID: userID)
                } catch {
                    lastError = "Check-ins are saved on this device. Upload will be retried."
                    // A malformed/conflicting row must not hold up other answers.
                    // Keep it pending; never convert a rejection into an acknowledgement.
                    if let failure = error as? FeltStateUploadError, failure.isRecordRejection { continue }
                    return
                }
                let previousDestination = entry.uploadedDestination
                entry.uploadedDestination = destination
                do {
                    try context.save()
                } catch {
                    entry.uploadedDestination = previousDestination
                    lastError = "Could not save the upload confirmation. Check-ins will be retried."
                    return
                }
            }
        } while flushRequested && isEnabled && !Task.isCancelled
    }
}
