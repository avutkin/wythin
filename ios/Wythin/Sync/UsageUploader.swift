import Foundation
import SwiftData

/// Uploads buffered usage events (app foreground intervals + ECG-recording
/// wear sessions) to the backend. Called after logging an event and on app
/// foreground. Idempotent: the server dedupes on `clientEventId`, and rows are
/// marked synced locally so retries don't re-send.
actor UsageUploader {

    private let client: APIClient
    private let userID: String

    init(client: APIClient, userID: String) {
        self.client = client
        self.userID = userID
    }

    /// Flush all unsynced usage events from the local store in one batch.
    func flushPending(context: ModelContext) async {
        let descriptor = FetchDescriptor<UsageEventLog>(
            predicate: #Predicate { !$0.syncedToServer }
        )
        guard let pending = try? context.fetch(descriptor), !pending.isEmpty else { return }

        let payload = UsageUploadPayload(events: pending.map {
            UsageEventPayload(clientEventId: $0.clientEventId,
                              eventType:     $0.eventType,
                              ts:            ISO8601DateFormatter().string(from: $0.ts),
                              durationMs:    $0.durationMs)
        })
        do {
            try await client.uploadUsage(payload, userID: userID)
            for e in pending { e.syncedToServer = true }
            try? context.save()
        } catch {
            // Leave syncedToServer = false; retried on the next flush.
        }
    }
}
