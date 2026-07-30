import Foundation
import SwiftData

/// A locally-buffered app-usage event awaiting upload to the backend.
///
/// Two kinds:
///   - `"foreground"`     — the app was in the foreground; `durationMs` = active time.
///   - `"ecg_recording"`  — the strap was connected (connect→disconnect); `durationMs` = wear time.
///
/// `UsageUploader` flushes unsynced rows to `POST /v1/usage`. `clientEventId`
/// is the idempotency key the server dedupes on.
@Model
final class UsageEventLog {
    @Attribute(.unique) var clientEventId: String
    var eventType:      String     // "foreground" | "ecg_recording"
    var ts:             Date       // start of the interval
    var durationMs:     Int
    var syncedToServer: Bool

    init(eventType: String, ts: Date, durationMs: Int) {
        self.clientEventId  = UUID().uuidString
        self.eventType      = eventType
        self.ts             = ts
        self.durationMs     = durationMs
        self.syncedToServer = false
    }
}
