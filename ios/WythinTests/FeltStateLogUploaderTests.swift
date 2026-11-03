import XCTest
import SwiftData
@testable import Wythin

/// The check-in uploader. Same shape as `UsageUploaderTests`: an in-memory
/// container, a fake client behind the narrow protocol, and the watermark
/// rule — nothing already sent goes again, nothing after a failure advances.
final class FeltStateLogUploaderTests: XCTestCase {

    private let watermarkKey = "feltStateLogs.lastUploadedTimestamp"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: watermarkKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: watermarkKey)
        super.tearDown()
    }

    private func makeContext() -> ModelContext {
        let schema = Schema([FeltStateLog.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private final class RecordingClient: FeltStateAPIClient, @unchecked Sendable {
        var payloads: [FeltStateUploadPayload] = []
        func uploadFeltStateLog(_ payload: FeltStateUploadPayload, userID: String) async throws {
            payloads.append(payload)
        }
    }

    private final class FailingClient: FeltStateAPIClient, @unchecked Sendable {
        struct Boom: Error {}
        func uploadFeltStateLog(_ payload: FeltStateUploadPayload, userID: String) async throws {
            throw Boom()
        }
    }

    @MainActor
    func testPendingRowsUploadAndTheWatermarkAdvances() async {
        let context = makeContext()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(FeltStateLog(timestamp: t, kind: "moment", focus: 40, energy: nil, stress: 20,
                                    mood: 71, anxiety: nil, sleep: nil, dayKey: "2027-01-15",
                                    timezone: "America/Los_Angeles", wornMinutes: 13.2, stateKey: nil))
        let client = RecordingClient()

        await FeltStateLogUploader(client: client, userID: "u").flushPending(context: context)

        XCTAssertEqual(client.payloads.count, 1)
        XCTAssertEqual(UserDefaults.standard.object(forKey: watermarkKey) as? Date, t)
    }

    @MainActor
    func testAFailedUploadDoesNotAdvanceTheWatermark() async {
        let context = makeContext()
        context.insert(FeltStateLog(timestamp: .now, kind: "moment", focus: 40, energy: nil, stress: nil,
                                    mood: nil, anxiety: nil, sleep: nil, dayKey: nil, timezone: nil,
                                    wornMinutes: nil, stateKey: nil))

        await FeltStateLogUploader(client: FailingClient(), userID: "u").flushPending(context: context)

        XCTAssertNil(UserDefaults.standard.object(forKey: watermarkKey))
    }

    @MainActor
    func testRowsAtOrBeforeTheWatermarkAreNotResent() async {
        let context = makeContext()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(FeltStateLog(timestamp: t, kind: "moment", focus: 1, energy: nil, stress: nil,
                                    mood: nil, anxiety: nil, sleep: nil, dayKey: nil, timezone: nil,
                                    wornMinutes: nil, stateKey: nil))
        UserDefaults.standard.set(t, forKey: watermarkKey)
        let client = RecordingClient()

        await FeltStateLogUploader(client: client, userID: "u").flushPending(context: context)

        XCTAssertEqual(client.payloads.count, 0)
    }

    /// The wire shape the server was built against: snake_case keys, `kind`
    /// always present, and an untouched scale absent-or-null — never 50.
    func testPayloadEncodesTheServersKeysAndKeepsUntouchedNull() throws {
        let log = FeltStateLog(timestamp: Date(timeIntervalSince1970: 0), kind: "previous_day",
                               focus: 60, energy: nil, stress: 30, mood: nil, anxiety: 10, sleep: 35,
                               dayKey: "2026-09-13", timezone: "Europe/Lisbon", wornMinutes: nil,
                               stateKey: nil)
        let data = try JSONEncoder().encode(FeltStateUploadPayload(from: log))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["kind"] as? String, "previous_day")
        XCTAssertEqual(json["day_key"] as? String, "2026-09-13")
        XCTAssertEqual(json["timezone"] as? String, "Europe/Lisbon")
        XCTAssertEqual(json["sleep"] as? Double, 35)
        XCTAssertEqual(json["anxiety"] as? Double, 10)
        XCTAssertEqual(json["id"] as? String, log.id.uuidString)
        XCTAssertTrue(json["energy"] == nil || json["energy"] is NSNull, "untouched must not become a number")
        XCTAssertTrue(json["worn_minutes"] == nil || json["worn_minutes"] is NSNull)
        XCTAssertNil(json["dayKey"], "camelCase must not leak onto the wire")
    }

    /// A row from the August build has no kind; it is a moment.
    func testARowWithoutAKindUploadsAsAMoment() throws {
        let log = FeltStateLog(timestamp: .now, kind: nil, focus: 1, energy: nil, stress: nil, mood: nil,
                               anxiety: nil, sleep: nil, dayKey: nil, timezone: nil, wornMinutes: nil,
                               stateKey: nil)
        let data = try JSONEncoder().encode(FeltStateUploadPayload(from: log))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "moment")
    }
}
