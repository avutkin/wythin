import XCTest
import SwiftData
@testable import Wythin

/// `ModelContext` is not thread-safe and is bound to the actor that owns it.
/// AppEnvironment is `@MainActor`, so `modelContainer.mainContext` may only be
/// touched on the main actor — passing it somewhere that hops off main is a
/// crash waiting for a race to lose.
final class UsageUploaderTests: XCTestCase {

    private func makeContext() -> ModelContext {
        let schema = Schema([UsageEventLog.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private final class ThreadRecordingClient: UsageAPIClient, @unchecked Sendable {
        var uploadCount = 0
        func uploadUsage(_ payload: UsageUploadPayload, userID: String) async throws {
            uploadCount += 1
        }
    }

    private final class FailingClient: UsageAPIClient, @unchecked Sendable {
        struct Boom: Error {}
        func uploadUsage(_ payload: UsageUploadPayload, userID: String) async throws {
            throw Boom()
        }
    }

    // The crash this file exists for — a main-actor `ModelContext` used from a
    // background executor — is prevented by isolation, so the compiler is the
    // check, not a test: `flushPending` is `@MainActor`, and these tests would
    // not compile if it stopped being callable from the main actor.
    //
    // There is deliberately no thread-probe test. Any probe would have to sit in
    // the injected client, and `uploadUsage` is a nonisolated async function that
    // hops off the caller's executor by design — so it would report "not main"
    // whether or not the SwiftData work was correctly isolated.

    @MainActor
    func testFlushMarksUploadedEventsSynced() async {
        let context = makeContext()
        let event = UsageEventLog(eventType: "ecg_recording", ts: .now, durationMs: 5_000)
        context.insert(event)

        await UsageUploader(client: ThreadRecordingClient(), userID: "u")
            .flushPending(context: context)

        XCTAssertTrue(event.syncedToServer)
    }

    /// A failed upload must leave the row unsynced so the next flush retries it.
    @MainActor
    func testAFailedUploadLeavesTheEventForRetry() async {
        let context = makeContext()
        let event = UsageEventLog(eventType: "foreground", ts: .now, durationMs: 1_000)
        context.insert(event)

        await UsageUploader(client: FailingClient(), userID: "u").flushPending(context: context)

        XCTAssertFalse(event.syncedToServer)
    }

    @MainActor
    func testNothingIsUploadedWhenThereIsNothingPending() async {
        let client = ThreadRecordingClient()
        await UsageUploader(client: client, userID: "u").flushPending(context: makeContext())
        XCTAssertEqual(client.uploadCount, 0)
    }

    @MainActor
    func testAlreadySyncedEventsAreNotResent() async {
        let context = makeContext()
        let event = UsageEventLog(eventType: "foreground", ts: .now, durationMs: 1_000)
        event.syncedToServer = true
        context.insert(event)

        let client = ThreadRecordingClient()
        await UsageUploader(client: client, userID: "u").flushPending(context: context)

        XCTAssertEqual(client.uploadCount, 0)
    }
}
