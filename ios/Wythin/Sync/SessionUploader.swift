import Foundation
import SwiftData

/// Uploads sessions that failed to sync while offline.
/// Called on app foreground and after each successful server connection.
/// Main-actor isolated for the same reason as `UsageUploader`: it operates on
/// the caller's `ModelContext`, which is not thread-safe and belongs to the main
/// actor. An `actor` here would do SwiftData work on a background executor.
@MainActor
final class SessionUploader {

    private let client: APIClient
    private let userID: String

    init(client: APIClient, userID: String) {
        self.client = client
        self.userID = userID
    }

    /// Flush all unsynced sessions from the local SwiftData store.
    func flushPending(context: ModelContext) async {
        let descriptor = FetchDescriptor<HRVSession>(
            predicate: #Predicate { !$0.syncedToServer && $0.endedAt != nil }
        )
        guard let pending = try? context.fetch(descriptor), !pending.isEmpty else { return }

        for session in pending {
            do {
                let payload  = SessionPayload(from: session)
                let response = try await client.uploadSession(payload, userID: userID)
                session.syncedToServer  = true
                session.serverSessionID = response.id
                try? context.save()
            } catch {
                // Leave syncedToServer = false; will retry next flush
            }
        }
    }
}
